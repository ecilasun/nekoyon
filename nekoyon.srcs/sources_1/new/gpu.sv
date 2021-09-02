`timescale 1ns / 1ps

module gpu (
	input wire clock,
	input wire reset,
	// G-RAM
	output logic gramre = 1'b0,
	output logic [3:0] gramwe = 4'h0,
	output logic [31:0] gramdin = 32'd0,
	output logic [13:0] gramaddr = 14'd0,
	input wire [31:0] gramdout );

// -----------------------------------------------------------------------
// Internal wires and registers
// -----------------------------------------------------------------------

logic [13:0] PC = 14'd0;
logic [13:0] nextPC = 14'd0;
logic [31:0] instruction = 32'd0;

logic [15:0] imm16;
logic [3:0] opcode;
logic [3:0] rs1;
logic [3:0] rs2;
logic [3:0] rd;
logic rwe = 1'b0;
logic [31:0] rdin = 32'd0;
wire [31:0] rval1;
wire [31:0] rval2;

// -----------------------------------------------------------------------
// Register file
// -----------------------------------------------------------------------

gpuregisterfile GPURegFile(
	.clock(clock),
	.rs1(rs1),
	.rs2(rs2),
	.rd(rd),
	.wren(rwe), 
	.datain(rdin),
	.rval1(rval1),
	.rval2(rval2) );

// -----------------------------------------------------------------------
// Decoder
// -----------------------------------------------------------------------

always_comb begin
	// imm16            rd   rs2  rs1  op
	// 0000000000000000 0000 0000 0000 0000

	// if high bit of memory address is set: VRAM
	// if high bit of memory address is clear: G-RAM
	// default stack pointer is in G-RAM at 32'h0000FFF0, set by register g2

	opcode = instruction[3:0];
	rs1 = instruction[7:4];
	rs2 = instruction[11:8];
	rd = instruction[15:12];
	imm16 = instruction[31:16];
end

// -----------------------------------------------------------------------
// Core
// -----------------------------------------------------------------------

localparam GPU_RESET	= 0;
localparam GPU_RETIRE	= 1;
localparam GPU_FETCH	= 2;
localparam GPU_EXEC		= 3;
localparam GPU_LOAD		= 4;

logic [4:0] gpumode;

always @(posedge clock) begin
	if (reset) begin

		gpumode <= 0;
		gpumode[GPU_RESET] <= 1'b1;

	end else begin

		gpumode <= 0;

		case (1'b1)
			gpumode[GPU_RESET]: begin
				PC <= 14'd0;
				nextPC <= 14'd0;

				gpumode[GPU_RETIRE] <= 1'b1;
			end

			gpumode[GPU_FETCH]: begin
				// Stop read
				gramre <= 1'b0;
				// Feed decoder
				instruction <= gramdout;
				gpumode[GPU_EXEC] <= 1'b1;
			end

			gpumode[GPU_EXEC]: begin
				// Go to next instruction if we're not reading 'halt'
				if (opcode == 4'h0 && rs1[0] == 1'b0)
					nextPC <= PC;
				else // all other instructions including noop drop here
					nextPC <= PC + 14'd4;

				if (opcode == 4'h3) // load.w/h/b
					gpumode[GPU_LOAD] <= 1'b1;
				else
					gpumode[GPU_RETIRE] <= 1'b1;

				case (opcode)
					4'h0: begin
						// halt (rs1[0] == 1'b0) 0x______00
						// noop (rs1[0] == 1'b1) 0x______10
						// NOTE: When GPU reads 'halt' it can't move ot the next instruction until
						// the CPU writes a 'noop' at that address, after which the GPU will resume
						// Default contents of G-RAM contain all 'halt' instructions so that GPU is forced
						// to re-read memory address zero at startup
					end
					4'h1: begin
						// 0xIIIIRSR1
						// rs2[0] contains the sub-op encoding
						// if rs1 is set to rd, this will essentially become 'replace 16 bits of register'
						// setregi.h imm, rs1, rd- set high 16 bits of register to imm16 and the rest to rs1
						// setregi.l imm, rs1, rd - set low 16 bits of register to imm16 and the rest to rs1
						if (rs2[0] == 1'b0)
							rdin <= {imm16, rval1[15:0]};
						else // rs2[1] == 1'b1
							rdin <= {rval1[31:16], imm16};
						rwe <= 1'b1;
					end
					4'h2: begin
						// 0x___S_RR2
						// imm16[1:0] contains the sub-op encoding
						// store.w rs1, rs2- store word contained in rs1 at G-RAM address in rs2
						// store.h rs1, rs2- store halfword contained in rs1[15:0] at G-RAM address in rs2
						// store.b rs1, rs2 - store byte contained in rs1[7:0] at G-RAM address in rs2

						//if (rval2[31] == 1'b0) begin // G-RAM
							gramaddr <= rval2[15:2]; // DWORD aligned
							if (imm16[1:0] == 2'b00) begin // store.w
								gramdin <= rval1;
								gramwe <= 4'hF;
							end else if (imm16[1:0] == 2'b01) begin // store.h
								gramdin <= {rval1[15:0], rval1[15:0]};
								case (rval2[1])
									1'b1: begin gramwe <= 4'hC; end
									1'b0: begin gramwe <= 4'h3; end
								endcase
							end else if (imm16[1:0] == 2'b10) begin // store.b
								gramdin <= {rval1[7:0], rval1[7:0], rval1[7:0], rval1[7:0]};
								case (rval2[1:0])
									2'b11: begin gramwe <= 4'h8; end
									2'b10: begin gramwe <= 4'h4; end
									2'b01: begin gramwe <= 4'h2; end
									2'b00: begin gramwe <= 4'h1; end
								endcase
							end else begin // imm16[1:0] == 2'b11
								// noop
							end
						//end else begin
						//	TODO: store in VRAM
						//end
					end
					4'h3: begin
						// imm16[1:0] contains the sub-op encoding
						// 0x___SRR_3
						// load.w rs2, rd - load word contained at address rs2 in register rd
						// load.h rs2, rd - load halfword contained at address rs2 in register rd
						// load.b rs2, rd - load byte contained at address rs2 in register rd

						//if (rval2[31] == 1'b0) begin // G-RAM
							gramaddr <= rval2[15:2]; // DWORD aligned
							gramre <= 1'b1;
						//end else begin
						//	TODO: read from VRAM
						//end
					end
					4'h4: begin
						// imm16[1:0] contains the sub-op encoding
						// 0x___SRRR4
						// dma.w rs1, rs2, rd - copy words starting at G-RAM address rs2, to VRAM address starting at rd, for rs1 words
						// dma.h rs1, rs2, rd - copy words starting at G-RAM address rs2, to VRAM address starting at rd, for rs1 halfwords
						// dma.b rs1, rs2, rd - copy words starting at G-RAM address rs2, to VRAM address starting at rd, for rs1 bytes
						// dma.mw rs1, rs2, rd - copy words starting at G-RAM address rs2, to VRAM address starting at rd, for rs1 words, skipping zero
						// dma.mh rs1, rs2, rd - copy words starting at G-RAM address rs2, to VRAM address starting at rd, for rs1 halfwords, skipping zero
						// dma.mb rs1, rs2, rd - copy words starting at G-RAM address rs2, to VRAM address starting at rd, for rs1 bytes, skipping zero
					end
					4'h5: begin
						// 0x00000005
						// wpal rs1, rd - write 24bit color value from rs1[23:0] onto palette index at rd
					end
					4'h6: begin
						// 0x00000006
						// add rs1, rs2, rd
						// sub rs1, rs2, rd
						// div rs1, rs2, rd
						// mul rs1, rs2, rd
					end
					4'h7: begin
						// 0x00000007
						// bne rs1, rs2, rd
						// beq rs1, rs2, rd
						// ble rs1, rs2, rd
						// bl rs1, rs2, rd
						// jmp rs2(rd)
					end
					4'h8: begin
						// 0x00000008
						// addi rs1, imm16, rd
						// muli rs1, imm16, rd
					end
					4'h9: begin
						// 0x00000009
						// ret
					end
					4'hA: begin
						// 0x0000000A
						// wait for vsync
					end
					4'hB: begin
						// 0x0000000B
					end
					4'hC: begin
						// 0x0000000C
					end
					4'hD: begin
						// 0x0000000D
					end
					4'hE: begin
						// 0x0000000E
					end
					4'hF: begin
						// 0x0000000F
					end
				endcase
			end

			gpumode[GPU_LOAD]: begin
				gramre <= 1'b0;
				rwe <= 1'b1;
				if (imm16[1:0] == 2'b00) begin // load.w
					rdin <= gramdout[31:0];
				end else if (imm16[1:0] == 2'b01) begin // load.h
					case (gramaddr[1])
						1'b1: begin rdin <= {16'd0, gramdout[31:16]}; end
						1'b0: begin rdin <= {16'd0, gramdout[15:0]}; end
					endcase
				end else if (imm16[1:0] == 2'b10) begin // load.b
					case (gramaddr[1:0])
						2'b11: begin rdin <= {24'd0, gramdout[31:24]}; end
						2'b10: begin rdin <= {24'd0, gramdout[23:16]}; end
						2'b01: begin rdin <= {24'd0, gramdout[15:8]}; end
						2'b00: begin rdin <= {24'd0, gramdout[7:0]}; end
					endcase
				end else begin // imm16[1:0] == 2'b11
					// noop
				end
				gpumode[GPU_RETIRE] <= 1'b1;
			end

			gpumode[GPU_RETIRE]: begin
				// Stop register writes
				rwe <= 1'b0;
				// Stop memory writes
				gramwe <= 4'h0;

				// Set up address for instruction fetch
				PC <= nextPC;
				gramaddr <= nextPC;
				gramre <= 1'b1;

				gpumode[GPU_FETCH] <= 1'b1;
			end

		endcase
	end
end

endmodule

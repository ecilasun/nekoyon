`timescale 1ns / 1ps

module gpu (
	input wire clock,
	input wire reset,
	input wire [31:0] vsyncID,
	output logic videopage = 1'b0, // Current VRAM write page
	// V-RAM
	output logic [3:0] vramwe = 4'h0,
	output logic [31:0] vramdin = 32'd0,
	output logic [16:0] vramaddr = 17'd0,
	output logic [12:0] lanemask = 13'd0,
	// G-RAM
	output logic gramre = 1'b0,
	output logic [3:0] gramwe = 4'h0,
	output logic [31:0] gramdin = 32'd0,
	output logic [15:0] gramaddr = 16'd0,
	input wire [31:0] gramdout,
	// P-RAM
	output logic pramre = 1'b0,
	output logic [3:0] pramwe = 4'h0,
	output logic [31:0] pramdin = 32'd0,
	output logic [15:0] pramaddr = 16'd0,
	input wire [31:0] pramdout,
	// Palette
	output logic palettewe = 1'b0,
	output logic [7:0] paletteaddress = 8'h00,
	output logic [23:0] palettedata = 24'h000 );

// -----------------------------------------------------------------------
// Internal wires and registers
// -----------------------------------------------------------------------

logic [15:0] PC = 16'd0;
logic [15:0] nextPC = 16'd0;

logic [31:0] vsyncID1;
logic [31:0] vsyncID2;

logic [31:0] vsyncrequestpoint = 32'd0;
logic [15:0] imm16;
logic [3:0] opcode;
logic [3:0] rs1;
logic [3:0] rs2;
logic [3:0] rd;
logic rwe = 1'b0;
logic [31:0] rdin = 32'd0;
wire [31:0] rval1;
wire [31:0] rval2;
logic [2:0] aluop;
logic [31:0] aluA;
logic [31:0] aluB;

logic [31:0] dmasource;
logic [31:0] dmatarget;
logic [15:0] dmalength;

always @(posedge clock) begin
	vsyncID1 <= vsyncID;
	vsyncID2 <= vsyncID1;
end

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
// Integer ALU
// -----------------------------------------------------------------------

wire [31:0] aluout;

gpualu GPUIntegerALU(
	.aluop(aluop),
	.rval1(aluA),
	.rval2(aluB),
	.aluout(aluout) );

// -----------------------------------------------------------------------
// Core
// -----------------------------------------------------------------------

localparam GPU_RESET		= 0;
localparam GPU_RETIRE		= 1;
localparam GPU_FETCH		= 2;
localparam GPU_DECODE		= 3;
localparam GPU_EXEC			= 4;
localparam GPU_LOAD			= 5;
localparam GPU_WAITVSYNC	= 6;
localparam GPU_ALUWAIT		= 7;
localparam GPU_DMAKICK		= 8;
localparam GPU_DMASYNC		= 9;

logic [9:0] gpumode;

always @(posedge clock) begin
	if (reset) begin

		gpumode <= 0;
		gpumode[GPU_RESET] <= 1'b1;

	end else begin

		gpumode <= 0;

		case (1'b1)
			gpumode[GPU_RESET]: begin
				PC <= 16'd0;
				nextPC <= 16'd0;

				gpumode[GPU_RETIRE] <= 1'b1;
			end

			gpumode[GPU_FETCH]: begin
				// Stop read
				pramre <= 1'b0;
				// Set up vsync request point
				vsyncrequestpoint <= vsyncID2;
				gpumode[GPU_DECODE] <= 1'b1;
			end

			gpumode[GPU_DECODE]: begin
				// Instruction encoding:
				// imm16            rd   rs2  rs1  op
				// 0000000000000000 0000 0000 0000 0000
			
				// Default stack pointer is in P-RAM at 32'h0000FFF0, set by register r2

				opcode <= pramdout[2:0]; // instruction[3] is reserved
				rs1 <= pramdout[7:4];
				rs2 <= pramdout[11:8];
				rd <= pramdout[15:12];
				imm16 <= pramdout[31:16];
				aluop <= pramdout[18:16]; // imm16[2:0]

				gpumode[GPU_EXEC] <= 1'b1;
			end

			gpumode[GPU_EXEC]: begin
				// Default behavior
				nextPC <= PC + 16'd4;

				if (opcode == 3'h3) // load.w/h/b
					gpumode[GPU_LOAD] <= 1'b1;
				else if ((opcode == 3'h7) && (imm16[1:0]==2'b01)) // vsync
					gpumode[GPU_WAITVSYNC] <= 1'b1;
				else if (opcode == 3'h4) // dma
					gpumode[GPU_DMASYNC] <= 1'b1;
				else if (opcode == 3'h6) // alu
					gpumode[GPU_ALUWAIT] <= 1'b1;
				else
					gpumode[GPU_RETIRE] <= 1'b1;

				rwe <= 1'b0;

				case (opcode)
					3'h0: begin
						// imm16[2:0] contains the sub-op encoding
						// rs1 contains the compare result on lower 3 bits
						// 0x____RS_7
						// branch instructions use a link register to store current PC
						// jmp rs2 - this is also the 'ret' instruction - HALT encoded with rs2==r0, rs1 is ignored (set to r0)
						// bne rs2, rs1
						// beq rs2, rs1
						// ble rs2, rs1
						// bl rs2, rs1
						// bg rs2, rs1
						// bge rs2, rs1
						
						// jmp zero encodes as 0x00000000 (P-RAM start), a.k.a. HALT
						
						// Store return address in register so that call site may save it to stack
						rwe <= 1'b1;
						rdin <= PC + 16'd4;

						case (imm16[2:0])
							3'b000: begin // jmp
								nextPC <= rval2;
							end
							3'b001: begin // bne
								nextPC <= ~rval1[0] ? rval2 : PC;
							end
							3'b010: begin // beq
								nextPC <= rval1[0] ? rval2 : PC;
							end
							3'b011: begin // ble
								nextPC <= (rval1[1]|rval1[0]) ? rval2 : PC;
							end
							3'b100: begin // bl
								nextPC <= rval1[1] ? rval2 : PC;
							end
							3'b101: begin // bg
								nextPC <= rval1[2] ? rval2 : PC;
							end
							3'b110: begin // bge
								nextPC <= (rval1[2]|rval1[0]) ? rval2 : PC;
							end
						endcase
					end

					3'h1: begin
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

					3'h2: begin
						// 0x___S_RR2
						// imm16[1:0] contains the sub-op encoding
						// store.w rs1, rs2- store word contained in rs1 at G-RAM address in rs2
						// store.h rs1, rs2- store halfword contained in rs1[15:0] at G-RAM address in rs2
						// store.b rs1, rs2 - store byte contained in rs1[7:0] at G-RAM address in rs2
						
						// NOTE: Memory addresses map to different places from point of view of the GPU

						if (rval2[31:30] == 2'b01) begin // G-RAM - 0x40000000
							gramaddr <= rval2[15:0];
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
						end else if (rval2[31:30] == 2'b10) begin // V-RAM - 0x80000000
							vramaddr <= rval2[16:0];
							if (imm16[1:0] == 2'b00) begin // store.w
								vramdin <= rval1;
								vramwe <= 4'hF;
							end else if (imm16[1:0] == 2'b01) begin // store.h
								vramdin <= {rval1[15:0], rval1[15:0]};
								case (rval2[1])
									1'b1: begin vramwe <= 4'hC; end
									1'b0: begin vramwe <= 4'h3; end
								endcase
							end else if (imm16[1:0] == 2'b10) begin // store.b
								vramdin <= {rval1[7:0], rval1[7:0], rval1[7:0], rval1[7:0]};
								case (rval2[1:0])
									2'b11: begin vramwe <= 4'h8; end
									2'b10: begin vramwe <= 4'h4; end
									2'b01: begin vramwe <= 4'h2; end
									2'b00: begin vramwe <= 4'h1; end
								endcase
							end else begin // imm16[1:0] == 2'b11
								// noop
							end
						end else if (rval2[31:30] == 2'b00) begin // P-RAM - 0x00000000
							pramaddr <= rval2[15:0];
							if (imm16[1:0] == 2'b00) begin // store.w
								pramdin <= rval1;
								pramwe <= 4'hF;
							end else if (imm16[1:0] == 2'b01) begin // store.h
								pramdin <= {rval1[15:0], rval1[15:0]};
								case (rval2[1])
									1'b1: begin pramwe <= 4'hC; end
									1'b0: begin pramwe <= 4'h3; end
								endcase
							end else if (imm16[1:0] == 2'b10) begin // store.b
								pramdin <= {rval1[7:0], rval1[7:0], rval1[7:0], rval1[7:0]};
								case (rval2[1:0])
									2'b11: begin pramwe <= 4'h8; end
									2'b10: begin pramwe <= 4'h4; end
									2'b01: begin pramwe <= 4'h2; end
									2'b00: begin pramwe <= 4'h1; end
								endcase
							end else begin // imm16[1:0] == 2'b11
								// noop
							end
						end
					end

					3'h3: begin
						// imm16[1:0] contains the sub-op encoding
						// 0x___SRR_3
						// load.w rs2, rd - load word contained at address rs2 in register rd
						// load.h rs2, rd - load halfword contained at address rs2 in register rd
						// load.b rs2, rd - load byte contained at address rs2 in register rd

						if (rval2[31:30] == 2'b01) begin // G-RAM - 0x40000000
							gramaddr <= rval2[15:0];
							gramre <= 1'b1;
						end else if (rval2[31:30] == 2'b10) begin // V-RAM - 0x80000000
							// NOTE: Memory reads from VRAM are not possible at this point
						end else if (rval2[31:30] == 2'b00) begin // P-RAM - 0x00000000
							pramaddr <= rval2[15:0];
							pramre <= 1'b1;
						end
					end

					3'h4: begin
						// rd[1:0] contains the sub-op encoding
						// 0xIIIISRR4
						// dma.w rs1, rs2, rd - copy words starting at G-RAM address rs2, to VRAM address starting at rs1, for imm16 words
						// dma.h rs1, rs2, rd - copy halfwords starting at G-RAM address rs2, to VRAM address starting at rs1, for imm16 halfwords
						// dma.b rs1, rs2, rd - copy bytes starting at G-RAM address rs2, to VRAM address starting at rs1, for imm16 bytes
						// dma.mw rs1, rs2, rd - copy words starting at G-RAM address rs2, to VRAM address starting at rs1, for imm16 words, skipping zero
						// dma.mh rs1, rs2, rd - copy halfwords starting at G-RAM address rs2, to VRAM address starting at rs1, for imm16 halfwords, skipping zero
						// dma.mb rs1, rs2, rd - copy bytes starting at G-RAM address rs2, to VRAM address starting at rs1, for imm16 bytes, skipping zero

						// TODO: Might do it with a DMA list in memory at rs1, with DMA flags inregister rs2
						// and memory containing list of [DMALEN,SOURCE(G_RAM),DEST(V_RAM)], 12 bytes total for each entry
						// Could have a 'window' mode where [DMALEN,SOURCE,DEST,SRCSTRIDE,DSTSTRIDE,ROWS] can copy a rectangular region
						// Could have a 'fill' mode where [DMALEN,DEST,DSTSTRIDE,ROWS,VALUE] can fill a window with VALUE
						// DMA stops when DMALEN=0
						// Flags can contain the mask value (to ignore writes), and other DMA mode control

						dmasource <= rval1 + 32'd4; // Set next memory address ahead of time
						dmatarget <= rval2;			// Target start late, keep same address
						dmalength <= imm16;		    // DMA count in words

						gramaddr <= rval1[16:0];    // Use first memory address incoming from register for this clock
						gramre <= 1'b1;				// Start reading and keep enabled until we're done
					end

					3'h5: begin
						// 0x00000005
						// wpal rs1, rs2 - write 24bit color value from rs1[23:0] onto palette index at rs2
						// TODO: error diffusion dither helpers for RGB values?
						// ---- ---- ---- ---- IIII IIII DDDD MCCC
						paletteaddress <= rval2[7:0];
						palettedata <= rval1[23:0];
						palettewe <= 1'b1;
					end

					3'h6: begin
						// imm16[2:0] contains the sub-op encoding
						// 0x___SRRR6
						// cmp rs1, rs2, rd - compare rs1 to rs2 and set compare code
						// sub rs1, rs2, rd
						// div rs1, rs2, rd
						// mul rs1, rs2, rd
						// add rs1, rs2, rd
						// and rs1, rs2, rd
						// or rs1, rs2, rd
						// xor rs1, rs2, rd
						aluA <= rval1;
						aluB <= rval2;
					end

					3'h7: begin
						// imm16[1:0] contains the sub-op encoding
						// 0x___S___7
						// noop / vsync / vpage rs1

						case (imm16[1:0])
							2'b00: begin
								// noop
							end
							2'b01: begin // vsync
								//gpumode[GPU_WAITVSYNC] <= 1'b1; // NOTE: This is set above as it can't be set here
							end
							2'b10: begin // vpage
								videopage <= rval1; // Set V-RAM write page
							end
							2'b11: begin
								// reserved for future, acts as noop
							end
						endcase
					end
				endcase
			end
			
			gpumode[GPU_DMASYNC]: begin
				dmasource <= dmasource + 32'd4;
				gramaddr <= dmasource[16:0];
				gpumode[GPU_DMAKICK] <= 1'b1;
			end

			gpumode[GPU_DMAKICK]: begin
				if (dmalength == 16'd0) begin
					gpumode[GPU_RETIRE] <= 1'b1;
				end else begin
					dmalength <= dmalength - 16'd1;

					dmasource <= dmasource + 32'd4;
					gramaddr <= dmasource[16:0];

					dmatarget <= dmatarget + 32'd4;
					vramaddr <= dmatarget[17:0];
					vramdin <= gramdout;
					vramwe <= 4'hF;

					gpumode[GPU_DMAKICK] <= 1'b1;
				end
			end

			gpumode[GPU_ALUWAIT]: begin
				rwe <= 1'b1;
				rdin <= aluout;
				gpumode[GPU_RETIRE] <= 1'b1;
			end

			gpumode[GPU_WAITVSYNC]: begin
				if (vsyncID2 > vsyncrequestpoint) begin
					gpumode[GPU_RETIRE] <= 1'b1;
				end else begin
					gpumode[GPU_WAITVSYNC] <= 1'b1;
				end
			end

			gpumode[GPU_LOAD]: begin

				// Pending load from G-RAM
				if (gramre) begin
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
				end

				// Pending load from P-RAM
				if (pramre) begin
					pramre <= 1'b0;
					rwe <= 1'b1;
					if (imm16[1:0] == 2'b00) begin // load.w
						rdin <= pramdout[31:0];
					end else if (imm16[1:0] == 2'b01) begin // load.h
						case (pramaddr[1])
							1'b1: begin rdin <= {16'd0, pramdout[31:16]}; end
							1'b0: begin rdin <= {16'd0, pramdout[15:0]}; end
						endcase
					end else if (imm16[1:0] == 2'b10) begin // load.b
						case (pramaddr[1:0])
							2'b11: begin rdin <= {24'd0, pramdout[31:24]}; end
							2'b10: begin rdin <= {24'd0, pramdout[23:16]}; end
							2'b01: begin rdin <= {24'd0, pramdout[15:8]}; end
							2'b00: begin rdin <= {24'd0, pramdout[7:0]}; end
						endcase
					end else begin // imm16[1:0] == 2'b11
						// noop
					end
				end

				gpumode[GPU_RETIRE] <= 1'b1;
			end

			gpumode[GPU_RETIRE]: begin
				// Stop register/palette/memory writes
				rwe <= 1'b0;
				palettewe <= 1'b0;
				gramwe <= 4'h0;
				pramwe <= 4'h0;
				vramwe <= 4'h0;

				// Set up address for instruction fetch from P-RAM
				PC <= nextPC;
				pramaddr <= nextPC;
				pramre <= 1'b1;

				gpumode[GPU_FETCH] <= 1'b1;
			end

		endcase
	end
end

endmodule

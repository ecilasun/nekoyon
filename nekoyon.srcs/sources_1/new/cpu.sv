`timescale 1ns / 1ps

// -----------------------------------------------------------------------
// CPU
// -----------------------------------------------------------------------

module cpu(
	input wire clock,
	input wire wallclock,
	input wire reset,
	input wire businitialized,
	input wire busbusy,
	output logic [31:0] busaddress = 32'd0,
	inout wire [31:0] busdata,
	output logic [3:0] buswe = 4'h0,
	output logic busre = 1'b0 );

// -----------------------------------------------------------------------
// Bidirectional bus logic
// -----------------------------------------------------------------------

logic [31:0] dataout = 32'd0;
assign busdata = (|buswe) ? dataout : 32'dz;

// -----------------------------------------------------------------------
// Internal state
// -----------------------------------------------------------------------

logic [31:0] PC;
logic [31:0] nextPC;
logic [31:0] instruction;
localparam RESETVECTOR = 32'h10000000; // Top of S-RAM

// -----------------------------------------------------------------------
// Decoder
// -----------------------------------------------------------------------

wire [4:0] opcode;
wire [3:0] aluop;
wire [3:0] bluop;
wire [2:0] func3;
wire [6:0] func7;
wire [11:0] func12;
wire [4:0] rs1;
wire [4:0] rs2;
wire [4:0] rs3;
wire [4:0] rd;
wire [11:0] csrindex;
wire [31:0] immed;
wire selectimmedasrval2;

decoder InstructionDecoder(
	.instruction(instruction),
	.opcode(opcode),
	.aluop(aluop),
	.bluop(bluop),
	.func3(func3),
	.func7(func7),
	.func12(func12),
	.rs1(rs1),
	.rs2(rs2),
	.rs3(rs3),
	.rd(rd),
	.csrindex(csrindex),
	.immed(immed),
	.selectimmedasrval2(selectimmedasrval2) );

// -----------------------------------------------------------------------
// Integer register file
// -----------------------------------------------------------------------

wire [31:0] rval1;
wire [31:0] rval2;
logic rwe = 1'b0;
logic [31:0] rdin;

registerfile IntegerRegFile(
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
IALU IntegerALU(
	.aluout(aluout),
	.func3(func3),
	.val1(rval1),
	.val2(selectimmedasrval2 ? immed : rval2),
	.aluop(aluop) );

// -----------------------------------------------------------------------
// Branch ALU
// -----------------------------------------------------------------------

wire branchout;
BALU BranchALU(
	.clock(clock),
	.branchout(branchout),
	.val1(rval1),
	.val2(rval2),
	.bluop(bluop) );

// -----------------------------------------------------------------------
// Core
// -----------------------------------------------------------------------

localparam CPU_RESET	= 0;
localparam CPU_RETIRE	= 1;
localparam CPU_FETCH	= 2;
localparam CPU_DECODE	= 3;
localparam CPU_EXEC		= 4;
localparam CPU_LOAD		= 5;
logic [5:0] cpumode;

logic [31:0] immreach;
logic [31:0] immpc;
logic [31:0] pc4;
logic [31:0] branchpc;

always_comb begin
	immreach = rval1 + immed;
	immpc = PC + immed;
	pc4 = PC + 32'd4;
	branchpc = PC + (branchout ? immed : 32'd4);
end

always @(posedge clock or posedge reset) begin

	if (reset) begin

		cpumode <= 0;
		cpumode[CPU_RESET] <= 1'b1;

	end else begin

		cpumode <= 0;

		case (1'b1)

			cpumode[CPU_RESET]: begin
				PC <= RESETVECTOR;
				nextPC <= RESETVECTOR;
				cpumode[CPU_RETIRE] <= 1'b1;
			end

			cpumode[CPU_FETCH]: begin
				busre <= 1'b0;
				if (busbusy) begin
					cpumode[CPU_FETCH] <= 1'b1;
				end else begin
					instruction <= busdata;
					cpumode[CPU_DECODE] <= 1'b1;
				end
			end

			cpumode[CPU_DECODE]: begin
				nextPC <= pc4;
				if (opcode == `OPCODE_LOAD || opcode == `OPCODE_FLOAT_LDW) begin
					busaddress <= immreach;
					busre <= 1'b1;
					cpumode[CPU_LOAD] <= 1'b1;
				end else if (opcode == `OPCODE_STORE || opcode == `OPCODE_FLOAT_STW) begin
					busaddress <= immreach;
					case (func3)
						3'b000: begin // BYTE
							dataout <= {rval2[7:0], rval2[7:0], rval2[7:0], rval2[7:0]};
							unique case (immreach[1:0])
								2'b11: begin buswe <= 4'h8; end
								2'b10: begin buswe <= 4'h4; end
								2'b01: begin buswe <= 4'h2; end
								2'b00: begin buswe <= 4'h1; end
							endcase
						end
						3'b001: begin // WORD
							dataout <= {rval2[15:0], rval2[15:0]};
							unique case (immreach[1])
								1'b1: begin buswe <= 4'hC; end
								1'b0: begin buswe <= 4'h3; end
							endcase
						end
						default: begin // DWORD
							dataout <= /*(opcode == `OPCODE_FLOAT_STW) ? frval2 :*/ rval2;
							buswe <= 4'hF;
						end
					endcase
					cpumode[CPU_RETIRE] <= 1'b1;
				end else begin
					cpumode[CPU_EXEC] <= 1'b1;
				end
			end
			
			cpumode[CPU_LOAD]: begin
				busre <= 1'b0;
				if (busbusy) begin
					cpumode[CPU_LOAD] <= 1'b1;
				end else begin
					/*if (opcode == `OPCODE_FLOAT_LDW) begin
						fregwena <= 1'b1;
					end else begin*/
						rwe <= 1'b1;
					/*end*/
					unique case (func3)
						3'b000: begin // BYTE with sign extension
							unique case (busaddress[1:0])
								2'b11: begin rdin <= {{24{busdata[31]}}, busdata[31:24]}; end
								2'b10: begin rdin <= {{24{busdata[23]}}, busdata[23:16]}; end
								2'b01: begin rdin <= {{24{busdata[15]}}, busdata[15:8]}; end
								2'b00: begin rdin <= {{24{busdata[7]}},  busdata[7:0]}; end
							endcase
						end
						3'b001: begin // WORD with sign extension
							unique case (busaddress[1])
								1'b1: begin rdin <= {{16{busdata[31]}}, busdata[31:16]}; end
								1'b0: begin rdin <= {{16{busdata[15]}}, busdata[15:0]}; end
							endcase
						end
						3'b010: begin // DWORD
							/*if (opcode == `OPCODE_FLOAT_LDW)
								fregdata <= busdata[31:0];
							else*/
								rdin <= busdata[31:0];
						end
						3'b100: begin // BYTE with zero extension
							unique case (busaddress[1:0])
								2'b11: begin rdin <= {24'd0, busdata[31:24]}; end
								2'b10: begin rdin <= {24'd0, busdata[23:16]}; end
								2'b01: begin rdin <= {24'd0, busdata[15:8]}; end
								2'b00: begin rdin <= {24'd0, busdata[7:0]}; end
							endcase
						end
						3'b101: begin // WORD with zero extension
							unique case (busaddress[1])
								1'b1: begin rdin <= {16'd0, busdata[31:16]}; end
								1'b0: begin rdin <= {16'd0, busdata[15:0]}; end
							endcase
						end
					endcase
					cpumode[CPU_RETIRE] <= 1'b1;
				end
			end

			cpumode[CPU_EXEC]: begin
				case (opcode)
					`OPCODE_AUPC: begin
						rwe <= 1'b1;
						rdin <= immpc;
					end
					`OPCODE_LUI: begin
						rwe <= 1'b1;
						rdin <= immed;
					end
					`OPCODE_JAL: begin
						rwe <= 1'b1;
						rdin <= pc4;
						nextPC <= immpc;
					end
					`OPCODE_OP, `OPCODE_OP_IMM: begin
						rwe <= 1'b1;
						rdin <= aluout;
					end
					`OPCODE_FLOAT_OP: begin
						// TBD
					end
					`OPCODE_FLOAT_MADD, `OPCODE_FLOAT_MSUB, `OPCODE_FLOAT_NMSUB, `OPCODE_FLOAT_NMADD: begin
						// TBD
					end
					`OPCODE_FENCE: begin
						// TBD
					end
					`OPCODE_SYSTEM: begin
						// TBD
					end
					`OPCODE_JALR: begin
						rwe <= 1'b1;
						rdin <= pc4;
						nextPC <= immreach;
					end
					`OPCODE_BRANCH: begin
						nextPC <= branchpc;
					end
					default: begin
						// TBD
					end
				endcase

				cpumode[CPU_RETIRE] <= 1'b1;
			end

			cpumode[CPU_RETIRE]: begin
				// Stop memory reads/writes
				buswe <= 1'b0;
				busre <= 1'b0;

				// End register writes
				rwe <= 1'b0;

				if (busbusy) begin
					cpumode[CPU_RETIRE] <= 1'b1;
				end else begin
					PC <= nextPC;
					// Re-enable memory reads if we're allowed to read
					busaddress <= nextPC;
					busre <= 1'b1;
					cpumode[CPU_FETCH] <= 1'b1;
				end
			end

		endcase
	end

end

endmodule

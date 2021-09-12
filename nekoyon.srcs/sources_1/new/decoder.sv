`timescale 1ns / 1ps

`include "cpuops.vh"

module decoder(
	input wire [31:0] instruction,		// Raw input instruction
	output wire [18:0] instrOneHot,		// Current instruction class
	output logic decie,					// Illegal instruction
	output logic [3:0] aluop,			// Current ALU op
	output logic [3:0] bluop,			// Current BLU op
	output logic [2:0] func3,			// Sub-instruction
	output logic [6:0] func7,			// Sub-instruction
	output logic [11:0] func12,			// Sub-instruction
	output logic [4:0] rs1,				// Source register one
	output logic [4:0] rs2,				// Source register two
	output logic [4:0] rs3,				// Used by fused multiplyadd/sub
	output logic [4:0] rd,				// Destination register
	output logic [4:0] csrindex,		// Index of selected CSR register
	output logic [31:0] immed,			// Unpacked immediate integer value
	output logic selectimmedasrval2		// Select rval2 or unpacked integer during EXEC
);

assign instrOneHot = {
	instruction[6:2]==`OPCODE_CUSTOM ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_OP ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_OP_IMM ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_LUI ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_STORE ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_LOAD ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_JAL ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_JALR ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_BRANCH ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_AUPC ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_FENCE ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_SYSTEM ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_FLOAT_OP ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_FLOAT_LDW ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_FLOAT_STW ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_FLOAT_MADD ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_FLOAT_MSUB ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_FLOAT_NMSUB ? 1'b1:1'b0,
	instruction[6:2]==`OPCODE_FLOAT_NMADD ? 1'b1:1'b0 };

always_comb begin
	case ({instruction[31:25], instruction[24:20]})
		12'h001: csrindex = `CSR_FFLAGS;
		12'h002: csrindex = `CSR_FRM;
		12'h003: csrindex = `CSR_FCSR;
		12'h300: csrindex = `CSR_MSTATUS;
		12'h301: csrindex = `CSR_MISA;
		12'h304: csrindex = `CSR_MIE;
		12'h305: csrindex = `CSR_MTVEC;
		12'h340: csrindex = `CSR_MSCRATCH;
		12'h341: csrindex = `CSR_MEPC;
		12'h342: csrindex = `CSR_MCAUSE;
		12'h343: csrindex = `CSR_MTVAL;
		12'h344: csrindex = `CSR_MIP;
		12'h780: csrindex = `CSR_DCSR;
		12'h781: csrindex = `CSR_DPC;
		12'h800: csrindex = `CSR_TIMECMPLO;
		12'h801: csrindex = `CSR_TIMECMPHI;
		12'hB00: csrindex = `CSR_CYCLELO;
		12'hB80: csrindex = `CSR_CYCLEHI;
		12'hC01: csrindex = `CSR_TIMELO;
		12'hC02: csrindex = `CSR_RETILO;
		12'hC81: csrindex = `CSR_TIMEHI;
		12'hC82: csrindex = `CSR_RETIHI;
		12'hF14: csrindex = `CSR_HARTID;
		default: csrindex = `CSR_UNUSED;
	endcase
end

always_comb begin

	rs1 = instruction[19:15];
	rs2 = instruction[24:20];
	rs3 = instruction[31:27];
	rd = instruction[11:7];
	func3 = instruction[14:12];
	func7 = instruction[31:25];
	func12 = instruction[31:20];
	selectimmedasrval2 = instrOneHot[`O_H_OP_IMM];

	case (1'b1)
		instrOneHot[`O_H_OP]: begin
			decie = 1'b0;
			immed = 32'd0;
			bluop = `ALU_NONE;
			if (instruction[25]==1'b0) begin
				// Base integer ALU instructions
				case (instruction[14:12])
					3'b000: aluop = instruction[30] == 1'b0 ? `ALU_ADD : `ALU_SUB;
					3'b001: aluop = `ALU_SLL;
					3'b010: aluop = `ALU_SLT;
					3'b011: aluop = `ALU_SLTU;
					3'b100: aluop = `ALU_XOR;
					3'b101: aluop = instruction[30] == 1'b0 ? `ALU_SRL : `ALU_SRA;
					3'b110: aluop = `ALU_OR;
					3'b111: aluop = `ALU_AND;
				endcase
			end else begin
				// M-extension instructions
				case (instruction[14:12])
					3'b000, 3'b001, 3'b010, 3'b011: aluop = `ALU_MUL;
					3'b100, 3'b101: aluop = `ALU_DIV;
					3'b110, 3'b111: aluop = `ALU_REM;
				endcase
			end
		end

		instrOneHot[`O_H_OP_IMM]: begin
			decie = 1'b0;
			immed = {{21{instruction[31]}},instruction[30:20]};
			bluop = `ALU_NONE;
			case (instruction[14:12])
				3'b000: aluop = `ALU_ADD; // NOTE: No immediate mode sub exists
				3'b001: aluop = `ALU_SLL;
				3'b010: aluop = `ALU_SLT;
				3'b011: aluop = `ALU_SLTU;
				3'b100: aluop = `ALU_XOR;
				3'b101: aluop = instruction[30] == 1'b0 ? `ALU_SRL : `ALU_SRA;
				3'b110: aluop = `ALU_OR;
				3'b111: aluop = `ALU_AND;
			endcase
		end

		instrOneHot[`O_H_LUI]: begin	
			decie = 1'b0;
			immed = {instruction[31:12], 12'd0};
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_FLOAT_STW], instrOneHot[`O_H_STORE]: begin
			decie = 1'b0;
			immed = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_FLOAT_LDW], instrOneHot[`O_H_LOAD]: begin
			decie = 1'b0;
			immed = {{20{instruction[31]}}, instruction[31:20]};
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_JAL]: begin
			decie = 1'b0;
			immed = {{12{instruction[31]}}, instruction[19:12], instruction[20], instruction[30:21], 1'b0};
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_JALR]: begin
			decie = 1'b0;
			immed = {{20{instruction[31]}}, instruction[31:20]};
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_BRANCH]: begin
			decie = 1'b0;
			immed = {{20{instruction[31]}}, instruction[7], instruction[30:25], instruction[11:8], 1'b0};
			aluop = `ALU_NONE;
			case (instruction[14:12])
				3'b000: bluop = `ALU_EQ;
				3'b001: bluop = `ALU_NE;
				3'b010: bluop = `ALU_NONE;
				3'b011: bluop = `ALU_NONE;
				3'b100: bluop = `ALU_L;
				3'b101: bluop = `ALU_GE;
				3'b110: bluop = `ALU_LU;
				3'b111: bluop = `ALU_GEU;
			endcase
		end

		instrOneHot[`O_H_AUPC]: begin
			decie = 1'b0;
			immed = {instruction[31:12], 12'd0};
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_FENCE]: begin
			decie = 1'b0;
			immed = 32'd0;
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_SYSTEM]: begin
			decie = 1'b0;
			immed = {27'd0, instruction[19:15]};
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_FLOAT_OP]: begin
			decie = 1'b0;
			immed = 32'd0;
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		instrOneHot[`O_H_FLOAT_MSUB], instrOneHot[`O_H_FLOAT_MADD], instrOneHot[`O_H_FLOAT_NMSUB], instrOneHot[`O_H_FLOAT_NMADD]: begin
			decie = 1'b0;
			immed = 32'd0;
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end

		default: begin
			decie = 1'b1;
			immed = 32'd0;
			aluop = `ALU_NONE;
			bluop = `ALU_NONE;
		end
	endcase
end

endmodule

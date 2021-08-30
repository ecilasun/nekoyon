`timescale 1ns / 1ps

`include "cpuops.vh"

module IALU(
	output logic [31:0] aluout = 32'd0,
	input wire [2:0] func3,
	input wire [31:0] val1,
	input wire [31:0] val2,
	input wire [3:0] aluop );
	
wire [9:0] aluOneHot = {
	aluop == `ALU_ADD ? 1'b1:1'b0,
	aluop == `ALU_SUB ? 1'b1:1'b0,
	aluop == `ALU_SLL ? 1'b1:1'b0,
	aluop == `ALU_SLT ? 1'b1:1'b0,
	aluop == `ALU_SLTU ? 1'b1:1'b0,
	aluop == `ALU_XOR ? 1'b1:1'b0,
	aluop == `ALU_SRL ? 1'b1:1'b0,
	aluop == `ALU_SRA ? 1'b1:1'b0,
	aluop == `ALU_OR ? 1'b1:1'b0,
	aluop == `ALU_AND ? 1'b1:1'b0 };

// Integer ALU
always_comb begin
	case (1'b1)
		// Integer ops
		aluOneHot[9]: aluout = val1 + val2;
		aluOneHot[8]: aluout = val1 + (~val2 + 32'd1);
		aluOneHot[7]: aluout = val1 << val2[4:0];
		aluOneHot[6]: aluout = $signed(val1) < $signed(val2) ? 32'd1 : 32'd0;
		aluOneHot[5]: aluout = val1 < val2 ? 32'd1 : 32'd0;
		aluOneHot[4]: aluout = val1 ^ val2;
		aluOneHot[3]: aluout = val1 >> val2[4:0];
		aluOneHot[2]: aluout = $signed(val1) >>> val2[4:0];
		aluOneHot[1]: aluout = val1 | val2;
		aluOneHot[0]: aluout = val1 & val2;
	endcase
end

endmodule

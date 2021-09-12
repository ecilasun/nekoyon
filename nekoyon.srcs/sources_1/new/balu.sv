`timescale 1ns / 1ps

`include "cpuops.vh"

module BALU(
	output logic branchout = 1'b0,
	input wire [31:0] val1,
	input wire [31:0] val2,
	input wire [3:0] bluop);

wire [5:0] aluonehot = {
	bluop == `ALU_EQ ? 1'b1 : 1'b0,
	bluop == `ALU_NE ? 1'b1 : 1'b0,
	bluop == `ALU_L ? 1'b1 : 1'b0,
	bluop == `ALU_GE ? 1'b1 : 1'b0,
	bluop == `ALU_LU ? 1'b1 : 1'b0,
	bluop == `ALU_GEU ? 1'b1 : 1'b0 };

// Branch ALU
// branchout will generate a latch
always_comb begin
	case (1'b1)
		// BRANCH ALU
		aluonehot[5]: branchout = val1 == val2 ? 1'b1 : 1'b0;
		aluonehot[4]: branchout = val1 != val2 ? 1'b1 : 1'b0;
		aluonehot[3]: branchout = $signed(val1) < $signed(val2) ? 1'b1 : 1'b0;
		aluonehot[2]: branchout = $signed(val1) >= $signed(val2) ? 1'b1 : 1'b0;
		aluonehot[1]: branchout = val1 < val2 ? 1'b1 : 1'b0;
		aluonehot[0]: branchout = val1 >= val2 ? 1'b1 : 1'b0;
	endcase
end

endmodule

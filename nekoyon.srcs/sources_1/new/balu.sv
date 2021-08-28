`timescale 1ns / 1ps

`include "cpuops.vh"

module BALU(
	input wire clock,
	output logic branchout = 1'b0,
	input wire [31:0] val1,
	input wire [31:0] val2,
	input wire [3:0] bluop);

// Branch ALU
always_comb begin
	case (bluop)
		// BRANCH ALU
		`ALU_EQ:   begin branchout = val1 == val2 ? 1'b1 : 1'b0; end
		`ALU_NE:   begin branchout = val1 != val2 ? 1'b1 : 1'b0; end
		`ALU_L:    begin branchout = $signed(val1) < $signed(val2) ? 1'b1 : 1'b0; end
		`ALU_GE:   begin branchout = $signed(val1) >= $signed(val2) ? 1'b1 : 1'b0; end
		`ALU_LU:   begin branchout = val1 < val2 ? 1'b1 : 1'b0; end
		`ALU_GEU:  begin branchout = val1 >= val2 ? 1'b1 : 1'b0; end
		//default:   begin branchout = 1'b0; end
	endcase
end

endmodule

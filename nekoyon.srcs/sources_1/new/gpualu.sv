`timescale 1ns / 1ps

module gpualu(
	input wire [2:0] aluop,
	input wire [31:0] rval1,
	input wire [31:0] rval2,
	output logic [31:0] aluout = 32'd0 );

// TODO: Use these pipelined versions from CPU side for mul and div
/*
wire [31:0] quotient;
wire [31:0] remainder;
DIV signeddivider (
	.clk(clock),
	.reset(reset),
	.start(gpumode[GPU_EXEC]),		// start signal
	.busy(divbusy),					// calculation in progress
	.dividend(rval1),
	.divisor(rval2),
	.quotient(quotient),			// result: div
	.remainder(remainder)			// result: rem
);

wire mulbusy;
wire [31:0] product;
multiplier themul(
    .clk(clock),
    .reset(reset),
    .start(gpumode[GPU_EXEC]),	// start signal
    .busy(mulbusy),				// calculation in progress
    .func3(3'b000),				// 3'b000 == `F3_MUL
    .multiplicand(rval1),
    .multiplier(rval2),
    .product(product) );*/

wire [7:0] aluOneHot = {
	aluop == 3'b111 ? 1'b1:1'b0,
	aluop == 3'b110 ? 1'b1:1'b0,
	aluop == 3'b101 ? 1'b1:1'b0,
	aluop == 3'b100 ? 1'b1:1'b0,
	aluop == 3'b011 ? 1'b1:1'b0,
	aluop == 3'b010 ? 1'b1:1'b0,
	aluop == 3'b001 ? 1'b1:1'b0,
	aluop == 3'b000 ? 1'b1:1'b0 };

always_comb begin
	case (1'b1)
		aluOneHot[0]: begin // cmp
			case (1'b1)
				(rval1==rval2): aluout = {29'd0, 3'h001};
				(rval1<rval2):  aluout = {29'd0, 3'b010};
				(rval1>rval2):  aluout = {29'd0, 3'b100};
			endcase
		end
		aluOneHot[1]: begin // sub
			aluout = rval1-rval2;
			//aluout = rval1 + (~rval2 + 32'd1);
		end
		aluOneHot[2]: begin // div - TODO: use pipelined version from CPU
			; // aluout = rval1/rval2;
		end
		aluOneHot[3]: begin // mul - TODO: use pipelined version from CPU
			; // aluout = rval1*rval2;
		end
		aluOneHot[4]: begin // add
			aluout = rval1 + rval2;
		end
		aluOneHot[5]: begin // and
			aluout = rval1 & rval2;
		end
		aluOneHot[6]: begin // or
			aluout = rval1 | rval2;
		end
		aluOneHot[7]: begin // xor
			aluout = rval1 ^ rval2;
		end
	endcase
end

endmodule

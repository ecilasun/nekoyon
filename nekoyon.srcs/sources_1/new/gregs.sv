`timescale 1ns / 1ps

module gpuregisterfile(
	input wire clock,			// Writes are clocked, reads are not
	input wire [3:0] rs1,		// Source register 1
	input wire [3:0] rs2,		// Source register 2
	input wire [3:0] rd,		// Destination register
	input wire wren,			// Write enable bit for writing to register rd 
	input wire [31:0] datain,	// Data to write to register rd
	output wire [31:0] rval1,	// Register values for rs1/2
	output wire [31:0] rval2 );

logic [31:0] registers[0:15]; 

initial begin
	registers[0]  <= 32'h00000000; // Zero register (as with RISCV)
	registers[1]  <= 32'h00000000; // Return address
	registers[2]  <= 32'h0000FFF0; // Stack pointer
	registers[3]  <= 32'h00000000;
	registers[4]  <= 32'h00000000;
	registers[5]  <= 32'h00000000;
	registers[6]  <= 32'h00000000;
	registers[7]  <= 32'h00000000;
	registers[8]  <= 32'h00000000;
	registers[9]  <= 32'h00000000;
	registers[10] <= 32'h00000000;
	registers[11] <= 32'h00000000;
	registers[12] <= 32'h00000000;
	registers[13] <= 32'h00000000;
	registers[14] <= 32'h00000000;
	registers[15] <= 32'h00000000;
end

always @(posedge clock) begin
	if (wren && rd != 4'd0)
		registers[rd] <= datain;
end

assign rval1 = registers[rs1];
assign rval2 = registers[rs2];

endmodule

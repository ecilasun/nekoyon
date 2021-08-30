`timescale 1ns / 1ps

module cache(
	input wire clock,
	input wire we,
	input wire ifetch,
	input wire [7:0] cline,
	input wire [255:0] cdin,
	input wire [15:0] ctagin,
	output wire [255:0] cdout,
	output wire [15:0] ctagout );

// Cache ranges:
// D$: 0..255
// I$: 256..511

logic [15:0] tags[0:511];
logic [255:0] lines[0:511];

initial begin
	integer i;
	// All pages are 'clean', all tags are invalid and cache is zeroed out by default
	for (int i=0;i<512;i=i+1) begin
		tags[i] = 16'h7FFF; // Top bit (line dirty flag) is set to zero by default
		lines[i] = 256'd0;
	end
end

always @(posedge clock) begin
	if (we) begin
		lines[{ifetch,cline}] <= cdin;
		tags[{ifetch,cline}] <= ctagin;
	end
end

assign cdout = lines[{ifetch,cline}];
assign ctagout = tags[{ifetch,cline}];

endmodule

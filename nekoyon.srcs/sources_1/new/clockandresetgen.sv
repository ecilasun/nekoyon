`timescale 1ns / 1ps

module clockandresetgen(
	input wire sys_clock_i,
	output wire wallclock,
	output wire cpuclock,
	output wire sys_clk_in,
	output wire ddr3_ref,
	output logic devicereset = 1'b1 );

wire clkAlocked, ddr3clklocked;

cpuclockgen CentralClock(
	.clk_in1(sys_clock_i),
	.wallclock(wallclock),
	.cpuclock(cpuclock),
	.locked(clkAlocked) );

DDR3Clocks DDR3MemoryClock(
	.clk_in1(sys_clock_i),
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
	.locked(ddr3clklocked));

// Hold reset until clocks are locked
wire internalreset = ~(clkAlocked & ddr3clklocked);

// Delayed reset post-clock-lock
logic [7:0] resetcountdown = 8'hFF;
always @(posedge wallclock) begin // Using slowest clock
	if (internalreset) begin
		resetcountdown <= 8'hFF;
		devicereset <= 1'b1;
	end else begin
		if (/*busready &&*/ (resetcountdown == 8'h00))
			devicereset <= 1'b0;
		else
			resetcountdown <= resetcountdown - 8'h01;
	end
end

endmodule

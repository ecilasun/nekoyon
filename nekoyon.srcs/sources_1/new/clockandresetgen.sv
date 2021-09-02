`timescale 1ns / 1ps

module clockandresetgen(
	input wire sys_clock_i,
	output wire wallclock,
	output wire spibaseclock,
	output wire cpuclock,
	output wire gpuclock,
	output wire sys_clk_in,
	output wire ddr3_ref,
	output logic devicereset = 1'b1 );

wire clkAlocked, ddr3clklocked;

cpuclockgen CentralClock(
	.clk_in1(sys_clock_i),
	.spibaseclock(spibaseclock),
	.wallclock(wallclock),
	.cpuclock(cpuclock),
	.gpuclock(gpuclock),
	.locked(clkAlocked) );

DDR3Clocks DDR3MemoryClock(
	.clk_in1(sys_clock_i),
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
	.locked(ddr3clklocked));

// Hold reset until clocks are locked
wire internalreset = ~(clkAlocked & ddr3clklocked);

// Delayed reset post-clock-lock
logic [3:0] resetcountdown = 4'hF;
always @(posedge wallclock) begin // Using slowest clock
	if (internalreset) begin
		resetcountdown <= 4'hF;
		devicereset <= 1'b1;
	end else begin
		if (/*busready &&*/ (resetcountdown == 4'h0))
			devicereset <= 1'b0;
		else
			resetcountdown <= resetcountdown - 4'h1;
	end
end

endmodule

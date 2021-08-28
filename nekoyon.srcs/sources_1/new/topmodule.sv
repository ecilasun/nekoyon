`timescale 1ns / 1ps

`default_nettype none

// ----------------------------------------------------------------------------
// NekoYon
// (c) 2021 Engin Cilasun
// ----------------------------------------------------------------------------

module topmodule(
	input wire sys_clock,
	output wire uart_rxd_out,
	input wire uart_txd_in );

// ----------------------------------------------------------------------------
// Clocks and reset
// ----------------------------------------------------------------------------

wire wallclock, cpuclock, reset;

clockandresetgen CoreClocksAndReset(
	.sys_clock_i(sys_clock),
	.wallclock(wallclock),
	.cpuclock(cpuclock),
	.devicereset(reset) );

// ----------------------------------------------------------------------------
// System Bus
// ----------------------------------------------------------------------------

wire businitialized;
wire busbusy;
wire [31:0] busaddress;
wire [31:0] busdata;
wire [3:0] buswe;
wire busre;

sysbus SystemBus(
	// Control
	.cpuclock(cpuclock),
	.clk10(wallclock),
	.reset(reset),
	.businitialized(businitialized),
	// Peripherals
	.uart_rxd_out(uart_rxd_out),
	.uart_txd_in(uart_txd_in),
	// Bus
	.busbusy(busbusy),
	.busaddress(busaddress),
	.busdata(busdata),
	.buswe(buswe),
	.busre(busre) );

// ----------------------------------------------------------------------------
// CPU
// ----------------------------------------------------------------------------

wire [3:0] diagnosis;

cpu CPUCore0(
	.clock(cpuclock),
	.wallclock(wallclock),
	.reset(reset),
	.businitialized(businitialized),
	.busbusy(busbusy),
	.busaddress(busaddress),
	.busdata(busdata),
	.buswe(buswe),
	.busre(busre) );

// ----------------------------------------------------------------------------
// TBD
// ----------------------------------------------------------------------------

endmodule

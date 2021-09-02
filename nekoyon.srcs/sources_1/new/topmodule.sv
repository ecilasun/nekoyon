`timescale 1ns / 1ps

`default_nettype none

// ----------------------------------------------------------------------------
// NekoYon
// (c) 2021 Engin Cilasun
// ----------------------------------------------------------------------------

module topmodule(
	input wire sys_clock,
	// UART
	output wire uart_rxd_out,
	input wire uart_txd_in,
    // DDR3
    output wire ddr3_reset_n,
    output wire [0:0] ddr3_cke,
    output wire [0:0] ddr3_ck_p, 
    output wire [0:0] ddr3_ck_n,
    output wire [0:0] ddr3_cs_n,
    output wire ddr3_ras_n, 
    output wire ddr3_cas_n, 
    output wire ddr3_we_n,
    output wire [2:0] ddr3_ba,
    output wire [13:0] ddr3_addr,
    output wire [0:0] ddr3_odt,
    output wire [1:0] ddr3_dm,
    inout wire [1:0] ddr3_dqs_p,
    inout wire [1:0] ddr3_dqs_n,
    inout wire [15:0] ddr3_dq,
    // SPI
	output wire spi_cs_n,
	output wire spi_mosi,
	input wire spi_miso,
	output wire spi_sck );

// ----------------------------------------------------------------------------
// Clocks and reset
// ----------------------------------------------------------------------------

wire wallclock, cpuclock, gpuclock, spibaseclock, reset;
wire sys_clk_in, ddr3_ref;

clockandresetgen CoreClocksAndReset(
	.sys_clock_i(sys_clock),
	.spibaseclock(spibaseclock),
	.wallclock(wallclock),
	.cpuclock(cpuclock),
	.gpuclock(gpuclock),
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
	.devicereset(reset) );

// ----------------------------------------------------------------------------
// System Bus
// ----------------------------------------------------------------------------

wire businitialized, busbusy, ifetch;
wire [31:0] busaddress;
wire [31:0] busdata;
wire [3:0] buswe;
wire busre;
wire irqtrigger;
wire [3:0] irqlines;

sysbus SystemBus(
	// Control
	.cpuclock(cpuclock),
	.gpuclock(gpuclock),
	.wallclock(wallclock),
	.spibaseclock(spibaseclock),
	.reset(reset),
	.businitialized(businitialized),
	// CPU
	.ifetch(ifetch),
	// UART
	.uart_rxd_out(uart_rxd_out),
	.uart_txd_in(uart_txd_in),
	// DDR3
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
    .ddr3_reset_n(ddr3_reset_n),
    .ddr3_cke(ddr3_cke),
    .ddr3_ck_p(ddr3_ck_p), 
    .ddr3_ck_n(ddr3_ck_n),
    .ddr3_cs_n(ddr3_cs_n),
    .ddr3_ras_n(ddr3_ras_n), 
    .ddr3_cas_n(ddr3_cas_n), 
    .ddr3_we_n(ddr3_we_n),
    .ddr3_ba(ddr3_ba),
    .ddr3_addr(ddr3_addr),
    .ddr3_odt(ddr3_odt),
    .ddr3_dm(ddr3_dm),
    .ddr3_dqs_p(ddr3_dqs_p),
    .ddr3_dqs_n(ddr3_dqs_n),
    .ddr3_dq(ddr3_dq),
    // SPI
    .spi_cs_n(spi_cs_n),
	.spi_mosi(spi_mosi),
	.spi_miso(spi_miso),
	.spi_sck(spi_sck),
    // Interrupts
	.irqtrigger(irqtrigger),
	.irqlines(irqlines),
    // Bus control
	.busbusy(busbusy),
	.busaddress(busaddress),
	.busdata(busdata),
	.buswe(buswe),
	.busre(busre) );

// ----------------------------------------------------------------------------
// CPU
// ----------------------------------------------------------------------------

cpu CPUCore0(
	.clock(cpuclock),
	.wallclock(wallclock),
	.reset(reset),
	.businitialized(businitialized),
	.busbusy(busbusy),
	.irqtrigger(irqtrigger),
	.irqlines(irqlines),
	.ifetch(ifetch),
	.busaddress(busaddress),
	.busdata(busdata),
	.buswe(buswe),
	.busre(busre) );

endmodule

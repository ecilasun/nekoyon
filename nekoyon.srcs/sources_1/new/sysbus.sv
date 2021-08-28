`timescale 1ns / 1ps

`include "cpuops.vh"

module sysbus(
	// Control
	input wire clk10,
	input wire cpuclock,
	input wire reset,
	output logic businitialized = 1'b0,
	output wire busbusy,
	// Peripherals
	output wire uart_rxd_out,
	input wire uart_txd_in,
	// Bus
	input wire [31:0] busaddress,
	inout wire [31:0] busdata,
	input wire [3:0] buswe,
	input wire busre );

// -----------------------------------------------------------------------
// Bidirectional bus logic
// -----------------------------------------------------------------------

logic [31:0] dataout = 32'd0;
assign busdata = (|buswe) ? 32'dz : dataout;

// ----------------------------------------------------------------------------
// Device ID Selector
// ----------------------------------------------------------------------------

wire [`DEVICE_COUNT-1:0] deviceSelect = {
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0010 ? 1'b1 : 1'b0,	// 04: 0x8xxxxx08 UART read/write port					+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0001 ? 1'b1 : 1'b0,	// 03: 0x8xxxxx04 UART incoming queue byte available	+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0000 ? 1'b1 : 1'b0,	// 02: 0x8xxxxx00 UART outgoing queue full				+
	(busaddress[31:28]==4'b0001) ? 1'b1 : 1'b0,							// 01: 0x10000000 - 0x1FFFFFFF - S-RAM (64Kbytes)		+
	(busaddress[31:28]==4'b0000) ? 1'b1 : 1'b0							// 00: 0x00000000 - 0x0FFFFFFF - DDR3 (256Mbytes)		-
};

// ----------------------------------------------------------------------------
// UART
// ----------------------------------------------------------------------------

wire uartwe = deviceSelect[`DEV_UARTRW] ? (|buswe) : 1'b0;
wire [31:0] uartdout;
wire uartreadbusy;

uartdriver UARTDevice(
	.deviceSelect(deviceSelect),
	.clk10(clk10),
	.cpuclock(cpuclock),
	.reset(reset),
	.buswe(uartwe),
	.busre(busre),
	.uartreadbusy(uartreadbusy),
	.busdata(busdata),
	.uartdout(uartdout),
	.uart_rxd_out(uart_rxd_out),
	.uart_txd_in(uart_txd_in) );

// ----------------------------------------------------------------------------
// S-RAM (also acts as boot ROM)
// ----------------------------------------------------------------------------

wire sramre = deviceSelect[`DEV_SRAM] ? busre : 1'b0;
wire [3:0] sramwe = deviceSelect[`DEV_SRAM] ? buswe : 4'h0;
wire [31:0] sramdin = deviceSelect[`DEV_SRAM] ? busdata : 32'd0;
wire [13:0] sramaddr = deviceSelect[`DEV_SRAM] ? busaddress[15:2] : 0;
wire [31:0] sramdout;

SRAMandBootROM SRAMBOOTRAMDevice(
	.addra(sramaddr),
	.clka(cpuclock),
	.dina(sramdin),
	.douta(sramdout),
	.ena(deviceSelect[`DEV_SRAM] & (sramre | (|sramwe))),
	.wea(sramwe) );

// -----------------------------------------------------------------------
// Bus state machine
// -----------------------------------------------------------------------

logic [3:0] busmode;

localparam BUS_RESET = 0;
localparam BUS_IDLE = 1;
localparam BUS_READ = 2;
localparam BUS_WRITE= 3;

wire busactive = busmode != BUS_IDLE;
assign busbusy = busactive | busre | (|buswe);
wire readbusy = uartreadbusy;

always @(posedge cpuclock or posedge reset) begin

	if (reset) begin

		busmode <= BUS_RESET;
		businitialized <= 1'b0;

	end else begin

		case (busmode)

			BUS_RESET: begin
				businitialized <= 1'b1;
				busmode <= BUS_IDLE;
			end

			BUS_IDLE: begin
				if (|buswe) begin
					busmode <= BUS_WRITE;
				end else if (busre) begin
					busmode <= BUS_READ;
				end else
					busmode <= BUS_IDLE;
			end

			BUS_READ: begin
				if (readbusy) begin
					// Stall while any device sets readbusy
					busmode <= BUS_READ;
				end else begin
					case (1'b1)
						deviceSelect[`DEV_SRAM]: begin
							dataout <= sramdout;
							busmode <= BUS_IDLE;
						end
						deviceSelect[`DEV_UARTRW],
						deviceSelect[`DEV_UARTBYTEAVAILABLE],
						deviceSelect[`DEV_UARTSENDFIFOFULL]: begin
							dataout <= uartdout;
							busmode <= BUS_IDLE;
						end
					endcase
				end
			end

			BUS_WRITE: begin
				busmode <= BUS_IDLE;
			end

		endcase

	end

end

endmodule

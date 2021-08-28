`timescale 1ns / 1ps

`include "cpuops.vh"

module uartdriver(
	input wire [`DEVICE_COUNT-1:0] deviceSelect,
	input wire clk10,
	input wire cpuclock,
	input wire reset,
	input wire buswe,
	input wire busre,
	output logic uartreadbusy = 1'b0,
	input wire [31:0] busdata,
	output logic [31:0] uartdout = 32'd0,
	output wire uart_rxd_out,
	input wire uart_txd_in);

// ----------------------------------------------------------------------------
// UART Transmitter
// ----------------------------------------------------------------------------

logic transmitbyte = 1'b0;
logic [7:0] datatotransmit = 8'h00;
wire uarttxbusy;

async_transmitter UART_transmit(
	.clk(clk10),
	.TxD_start(transmitbyte),
	.TxD_data(datatotransmit),
	.TxD(uart_rxd_out),
	.TxD_busy(uarttxbusy) );

logic [7:0] uartsenddin = 8'd0;
wire [7:0] uartsenddout;
logic uartsendwe = 1'b0, uartsendre = 1'b0;
wire uartsendfull, uartsendempty, uartsendvalid;

uartfifo UARTDataOutFIFO(
	.full(uartsendfull),
	.din(uartsenddin),
	.wr_en(uartsendwe),
	.wr_clk(cpuclock), // Write using cpu clock
	.empty(uartsendempty),
	.valid(uartsendvalid),
	.dout(uartsenddout),
	.rd_en(uartsendre),
	.rd_clk(clk10), // Read using UART base clock
	.rst(reset) );

always @(posedge cpuclock) begin
	uartsendwe <= 1'b0;
	// NOTE: CPU side checks for uartsendfull via software (read at 0x80000000) to decide whether to send or not
	if (buswe) begin
		uartsendwe <= 1'b1;
		uartsenddin <= busdata[7:0];
	end
end

logic [1:0] uartwritemode = 2'b00;
always @(posedge clk10) begin
	uartsendre <= 1'b0;
	transmitbyte <= 1'b0;
	case(uartwritemode)
		2'b00: begin // IDLE
			if (~uartsendempty & (~uarttxbusy)) begin
				uartsendre <= 1'b1;
				uartwritemode <= 2'b01; // WRITE
			end
		end
		2'b01: begin // WRITE
			if (uartsendvalid) begin
				transmitbyte <= 1'b1;
				datatotransmit <= uartsenddout;
				uartwritemode <= 2'b10; // FINALIZE
			end
		end
		2'b10: begin // FINALIZE
			// Need to give UARTTX one clock to
			// kick 'busy' for any adjacent
			// requests which didn't set busy yet
			uartwritemode <= 2'b00; // IDLE
		end
	endcase
end

// ----------------------------------------------------------------------------
// UART Receiver
// ----------------------------------------------------------------------------

wire uartbyteavailable;
wire [7:0] uartbytein;

async_receiver UART_receive(
	.clk(clk10),
	.RxD(uart_txd_in),
	.RxD_data_ready(uartbyteavailable),
	.RxD_data(uartbytein),
	.RxD_idle(),
	.RxD_endofpacket() );

wire uartrcvfull, uartrcvempty, uartrcvvalid;
logic [7:0] uartrcvdin;
wire [7:0] uartrcvdout;
logic uartrcvre = 1'b0, uartrcvwe = 1'b0;

uartfifo UARTDataInFIFO(
	.full(uartrcvfull),
	.din(uartrcvdin),
	.wr_en(uartrcvwe),
	.wr_clk(clk10),
	.empty(uartrcvempty),
	.dout(uartrcvdout),
	.rd_en(uartrcvre),
	.valid(uartrcvvalid),
	.rd_clk(cpuclock),
	.rst(reset) );

always @(posedge clk10) begin
	uartrcvwe <= 1'b0;
	if (uartbyteavailable) begin
		uartrcvwe <= 1'b1;
		uartrcvdin <= uartbytein;
	end
end

always @(posedge cpuclock) begin

	uartrcvre <= 1'b0;

	if (busre) begin
		case (1'b1)
			deviceSelect[`DEV_UARTRW]: begin
				uartdout <= 32'd0; // Will read zero if FIFO is empty
				uartrcvre <= (~uartrcvempty);
				uartreadbusy <= (~uartrcvempty);
			end
			deviceSelect[`DEV_UARTBYTEAVAILABLE]: begin
				uartdout <= {31'd0, (~uartrcvempty)};
				uartrcvre <= 1'b0; // no fifo read
				uartreadbusy <= 1'b0;
			end
			deviceSelect[`DEV_UARTSENDFIFOFULL]: begin
				uartdout <= {31'd0, uartsendfull};
				uartrcvre <= 1'b0; // no fifo read
				uartreadbusy <= 1'b0;
			end
		endcase
	end

	if (uartrcvvalid) begin
		uartdout <= {24'd0, uartrcvdout};
		uartreadbusy <= 1'b0;
	end
end

endmodule

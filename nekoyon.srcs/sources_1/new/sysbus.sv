`timescale 1ns / 1ps

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
// Device ID
// ----------------------------------------------------------------------------

localparam DEV_UARTRW				= 4;
localparam DEV_UARTBYTEAVAILABLE	= 3;
localparam DEV_UARTSENDFIFOFULL		= 2;
localparam DEV_SRAM					= 1;
localparam DEV_DDR3					= 0;

wire [4:0] deviceSelect = {
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0010 ? 1'b1 : 1'b0,	// 04: 0x8xxxxx08 UART read/write port					+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0001 ? 1'b1 : 1'b0,	// 03: 0x8xxxxx04 UART incoming queue byte available	+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0000 ? 1'b1 : 1'b0,	// 02: 0x8xxxxx00 UART outgoing queue full				+
	(busaddress[31:28]==4'b0001) ? 1'b1 : 1'b0,							// 01: 0x10000000 - 0x1FFFFFFF - S-RAM (64Kbytes)		+
	(busaddress[31:28]==4'b0000) ? 1'b1 : 1'b0							// 00: 0x00000000 - 0x0FFFFFFF - DDR3 (256Mbytes)		-
};

// ----------------------------------------------------------------------------
// UART Bus
// ----------------------------------------------------------------------------

wire uartwe = deviceSelect[DEV_UARTRW] ? (|buswe) : 1'b0;

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
	if (uartwe) begin
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

logic [31:0] uartdout;
logic uartreadbusy = 1'b0;
always @(posedge cpuclock) begin

	uartrcvre <= 1'b0;

	if (busre) begin
		case (1'b1)
			deviceSelect[DEV_UARTRW]: begin
				uartdout <= 32'd0; // Will read zero if FIFO is empty
				uartrcvre <= (~uartrcvempty);
				uartreadbusy <= (~uartrcvempty);
			end
			deviceSelect[DEV_UARTBYTEAVAILABLE]: begin
				uartdout <= {31'd0, (~uartrcvempty)};
				uartrcvre <= 1'b0; // no fifo read
				uartreadbusy <= 1'b0;
			end
			deviceSelect[DEV_UARTSENDFIFOFULL]: begin
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

// ----------------------------------------------------------------------------
// S-RAM (also acts as boot ROM)
// ----------------------------------------------------------------------------

wire sramre = deviceSelect[DEV_SRAM] ? busre : 1'b0;
wire [3:0] sramwe = deviceSelect[DEV_SRAM] ? buswe : 4'h0;
wire [31:0] sramdin = deviceSelect[DEV_SRAM] ? busdata : 32'd0;
wire [13:0] sramaddr = deviceSelect[DEV_SRAM] ? busaddress[15:2] : 0;
wire [31:0] sramdout;

SRAMandBootROM SysMemBootROM(
	.addra(sramaddr),
	.clka(cpuclock),
	.dina(sramdin),
	.douta(sramdout),
	.ena(deviceSelect[DEV_SRAM] & (sramre | (|sramwe))),
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
						deviceSelect[DEV_SRAM]: begin
							dataout <= sramdout;
							busmode <= BUS_IDLE;
						end
						deviceSelect[DEV_UARTRW],
						deviceSelect[DEV_UARTBYTEAVAILABLE],
						deviceSelect[DEV_UARTSENDFIFOFULL]: begin
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

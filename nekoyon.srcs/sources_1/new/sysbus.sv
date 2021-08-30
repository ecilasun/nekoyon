`timescale 1ns / 1ps

`include "cpuops.vh"

module sysbus(
	// Module control
	input wire clk10,
	input wire cpuclock,
	input wire reset,
	output logic businitialized = 1'b0,
	// CPU
	input wire ifetch, // High when fetching instructions, low otherwise
	// UART
	output wire uart_rxd_out,
	input wire uart_txd_in,
	// DDR3
	input wire sys_clk_in,
	input wire ddr3_ref,
    output wire ddr3_reset_n,
    output wire [0:0] ddr3_cke,
    output wire [0:0] ddr3_ck_p, 
    output wire [0:0] ddr3_ck_n,
    output wire [0:0] ddr3_cs_n,
    output wire ddr3_ras_n, 
    output wire ddr3_cas_n, 
    output wire ddr3_we_n,
    output [2:0] ddr3_ba,
    output [13:0] ddr3_addr,
    output [0:0] ddr3_odt,
    output [1:0] ddr3_dm,
    inout [1:0] ddr3_dqs_p,
    inout [1:0] ddr3_dqs_n,
    inout [15:0] ddr3_dq,
    // Interrupts
	output wire irqtrigger,
	output wire [3:0] irqlines,
	// Bus control
	output wire busbusy,
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
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0010 ? 1'b1 : 1'b0,	// 04: 0x8xxxxx08 UART read/write port					+DEV_UARTRW
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0001 ? 1'b1 : 1'b0,	// 03: 0x8xxxxx04 UART incoming queue byte available	+DEV_UARTBYTEAVAILABLE
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0000 ? 1'b1 : 1'b0,	// 02: 0x8xxxxx00 UART outgoing queue full				+DEV_UARTSENDFIFOFULL
	(busaddress[31:28]==4'b0001) ? 1'b1 : 1'b0,							// 01: 0x10000000 - 0x1FFFFFFF - S-RAM (64Kbytes)		+DEV_SRAM
	(busaddress[31:28]==4'b0000) ? 1'b1 : 1'b0							// 00: 0x00000000 - 0x0FFFFFFF - DDR3 (256Mbytes)		+DEV_DDR3
};

// ----------------------------------------------------------------------------
// UART
// ----------------------------------------------------------------------------

wire uartwe = deviceSelect[`DEV_UARTRW] ? (|buswe) : 1'b0;
wire [31:0] uartdout;
wire uartreadbusy, uartrcvempty;

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
	.uartrcvempty(uartrcvempty),
	.uart_rxd_out(uart_rxd_out),
	.uart_txd_in(uart_txd_in) );

// ----------------------------------------------------------------------------
// DDR3
// ----------------------------------------------------------------------------

wire calib_done;
wire ddr3readvalid;
wire ddr3readempty;
logic ddr3cmdwe = 1'b0;
logic ddr3readre = 1'b0;
logic [152:0] ddr3cmdin = 153'd0;
wire [127:0] ddr3readout;
wire ddr3ready;

ddr3driver DDR3Device(
	// Clock and reset
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
	.cpuclock(cpuclock),
	.reset(reset),
	// DDR3 wires
	.calib_done(calib_done),
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
    // Bus interface
    .ddr3ready(ddr3ready),
	.ddr3readvalid(ddr3readvalid),
	.ddr3readempty(ddr3readempty),
	.ddr3readre(ddr3readre),
	.ddr3cmdwe(ddr3cmdwe),
	.ddr3cmdin(ddr3cmdin),
	.ddr3readout(ddr3readout) );

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

// ----------------------------------------------------------------------------
// External interrupts
// ----------------------------------------------------------------------------

assign irqlines = {3'b000, ~uartrcvempty}; // TODO: Generate interrupt bits for more devices
assign irqtrigger = |irqlines;

// ----------------------------------------------------------------------------
// Cache wiring
// ----------------------------------------------------------------------------

// The division of address into cache, device and byte index data is as follows
// device  tag                 line       offset  byteindex
// 0000    000 0000 0000 0000  0000 0000  000     00

// The cache behavior:
// - On cache miss:
//   - Is old cache line dirty?
//     - Y: Flush old line to DDR3, load new line
//     - N: Load new line, discard old contents
// - On cache hit:
//   - Proceed with read or write at same speed as S-RAM

logic [31:0] cwidemask	= 32'd0;	// Wide mask generate from write mask
logic [15:0] oldtag		= 16'd0;	// Previous ctag + dirty bit

wire [14:0] ctag = busaddress[27:13]; // Ignore 4 highest bits (device ID) since only r/w for DDR3 are routed here
wire [7:0] cline = busaddress[12:5];  // D$:0..255, I$:256..511 via ifetch flag used as extra upper bit: {ifetch,cline}
wire [2:0] coffset = busaddress[4:2]; // 8xDWORD (256bits), DWORD select line

logic cwe = 1'b0;
logic [255:0] cdin = 256'd0;
logic [15:0] ctagin = 16'd0;
wire [255:0] cdout;
wire [15:0] ctagout;

// NOTE: D$ lines with dirty bits set won't make it to I$ without a write back to DDR3
// (which only happens when tag for the cache line changes in Neko architecture)
// For now, software will read of first 2048 DWORDs from DDR3 to force writebacks of
// dirty pages to memory, ensuring I$ can see these when it tries to access them.
cache IDCache(
	.clock(cpuclock),
	.we(cwe),
	.ifetch(ifetch),
	.cline(cline),
	.cdin(cdin),
	.ctagin(ctagin),
	.cdout(cdout),
	.ctagout(ctagout) );

logic loadindex = 1'b0;
logic [255:0] currentcacheline;

// -----------------------------------------------------------------------
// Bus state machine
// -----------------------------------------------------------------------

logic [3:0] busmode;

localparam BUS_RESET = 0;
localparam BUS_IDLE = 1;
localparam BUS_READ = 2;
localparam BUS_WRITE = 3;
localparam BUS_DDR3CACHESTOREHI = 4;
localparam BUS_DDR3CACHELOADLO = 5;
localparam BUS_DDR3CACHELOADHI = 6;
localparam BUS_DDR3CACHEWAIT = 7;
localparam BUS_DDR3UPDATECACHELINE = 8;
localparam BUS_UPDATEFINALIZE = 9;

wire busactive = busmode != BUS_IDLE;
assign busbusy = busactive | busre | (|buswe);
wire readbusy = uartreadbusy;
logic [31:0] ddr3wdat = 32'd0;
logic ddr3rw = 1'b0;

always @(posedge cpuclock) begin

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
				// Stop cache writes
				cwe <= 1'b0;

				if (deviceSelect[`DEV_DDR3] & (busre | (|buswe))) begin
					currentcacheline <= cdout;
					oldtag <= ctagout;
					cdin <= cdout;
					ctagin <= ctagout;
					cwidemask <= {{8{buswe[3]}}, {8{buswe[2]}}, {8{buswe[1]}}, {8{buswe[0]}}};
					ddr3wdat <= busdata;
				end else begin
					currentcacheline <= 256'd0;
					oldtag <= 16'd0;
					cdin <= 256'd0;
					ctagin <= 16'd0;
					cwidemask <= 32'd0;
					ddr3wdat <= 32'd0;
				end

				if (|buswe) begin
					busmode <= BUS_WRITE;
				end else if (busre) begin
					busmode <= BUS_READ;
				end else
					busmode <= BUS_IDLE;
			end

			BUS_READ: begin
				cwe <= 1'b0;
				if (readbusy) begin
					// Stall while any device sets readbusy
					busmode <= BUS_READ;
				end else begin
					busmode <= BUS_IDLE;
					case (1'b1)
						deviceSelect[`DEV_DDR3]: begin
							if (oldtag[14:0] == ctag) begin
								case (coffset)
									3'b000: dataout <= currentcacheline[31:0];
									3'b001: dataout <= currentcacheline[63:32];
									3'b010: dataout <= currentcacheline[95:64];
									3'b011: dataout <= currentcacheline[127:96];
									3'b100: dataout <= currentcacheline[159:128];
									3'b101: dataout <= currentcacheline[191:160];
									3'b110: dataout <= currentcacheline[223:192];
									3'b111: dataout <= currentcacheline[255:224];
								endcase
							end else begin
								ddr3rw <= 1'b0;
								// Do we need to flush then populate?
								if (oldtag[15]) begin
									// Write back old cache line contents to old address
									ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b0, currentcacheline[127:0]};
									ddr3cmdwe <= 1'b1;
									busmode <= BUS_DDR3CACHESTOREHI;
								end else begin
									// Load contents to new address, discarding current cache line (either evicted or discarded)
									ddr3cmdin <= {1'b0, ctag, cline, 1'b0, 128'd0};
									ddr3cmdwe <= 1'b1;
									busmode <= BUS_DDR3CACHELOADHI;
								end
							end
						end
						deviceSelect[`DEV_SRAM]: begin
							dataout <= sramdout;
						end
						deviceSelect[`DEV_UARTRW],
						deviceSelect[`DEV_UARTBYTEAVAILABLE],
						deviceSelect[`DEV_UARTSENDFIFOFULL]: begin
							dataout <= uartdout;
						end
					endcase
				end
			end

			BUS_WRITE: begin

				case(1'b1)
					deviceSelect[`DEV_DDR3]: begin
						if (oldtag[14:0] == ctag) begin
							cwe <= 1'b1;
							case (coffset)
								3'b000: cdin[31:0] <= ((~cwidemask)&currentcacheline[31:0]) | (cwidemask&ddr3wdat);
								3'b001: cdin[63:32] <= ((~cwidemask)&currentcacheline[63:32]) | (cwidemask&ddr3wdat);
								3'b010: cdin[95:64] <= ((~cwidemask)&currentcacheline[95:64]) | (cwidemask&ddr3wdat);
								3'b011: cdin[127:96] <= ((~cwidemask)&currentcacheline[127:96]) | (cwidemask&ddr3wdat);
								3'b100: cdin[159:128] <= ((~cwidemask)&currentcacheline[159:128]) | (cwidemask&ddr3wdat);
								3'b101: cdin[191:160] <= ((~cwidemask)&currentcacheline[191:160]) | (cwidemask&ddr3wdat);
								3'b110: cdin[223:192] <= ((~cwidemask)&currentcacheline[223:192]) | (cwidemask&ddr3wdat);
								3'b111: cdin[255:224] <= ((~cwidemask)&currentcacheline[255:224]) | (cwidemask&ddr3wdat);
							endcase
							// This cache line is now dirty
							ctagin[15] <= 1'b1;
							busmode <= BUS_IDLE;
						end else begin
							ddr3rw <= 1'b1;
							// Do we need to flush then populate?
							if (oldtag[15]) begin
								// Write back old cache line contents to old address
								ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b0, currentcacheline[127:0]};
								ddr3cmdwe <= 1'b1;
								busmode <= BUS_DDR3CACHESTOREHI;
							end else begin
								// Load contents to new address, discarding current cache line (either evicted or discarded)
								ddr3cmdin <= {1'b0, ctag, cline, 1'b0, 128'd0};
								ddr3cmdwe <= 1'b1;
								busmode <= BUS_DDR3CACHELOADHI;
							end
						end
					end
					default: begin
						busmode <= BUS_IDLE;
					end
				endcase
			end

			BUS_DDR3CACHESTOREHI: begin
				ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b1, currentcacheline[255:128]}; // STOREHI
				ddr3cmdwe <= 1'b1;
				busmode <= BUS_DDR3CACHELOADLO;
			end

			BUS_DDR3CACHELOADLO: begin
				ddr3cmdin <= {1'b0, ctag, cline, 1'b0, 128'd0}; // LOADLO
				ddr3cmdwe <= 1'b1;
				busmode <= BUS_DDR3CACHELOADHI;
			end

			BUS_DDR3CACHELOADHI: begin
				ddr3cmdin <= {1'b0, ctag, cline, 1'b1, 128'd0}; // LOADHI
				ddr3cmdwe <= 1'b1;
				loadindex <= 1'b0;
				busmode <= BUS_DDR3CACHEWAIT;
			end

			BUS_DDR3CACHEWAIT: begin
				ddr3cmdwe <= 1'b0;
				if (~ddr3readempty) begin
					// Read result available for this cache line
					// Request to read it
					ddr3readre <= 1'b1;
					busmode <= BUS_DDR3UPDATECACHELINE;
				end else begin
					busmode <= BUS_DDR3CACHEWAIT;
				end
			end

			BUS_DDR3UPDATECACHELINE: begin
				// Stop result read request
				ddr3readre <= 1'b0;
				// New cache line read and ready
				if (ddr3readvalid) begin
					case (loadindex)
						1'b0: begin
							currentcacheline[127:0] <= ddr3readout;
							loadindex <= 1'b1;
							// Read one more
							busmode <= BUS_DDR3CACHEWAIT;
						end
						1'b1: begin
							currentcacheline[255:128] <= ddr3readout;
							busmode <= BUS_UPDATEFINALIZE;
						end
					endcase
				end else begin
					busmode <= BUS_DDR3UPDATECACHELINE;
				end
			end

			BUS_UPDATEFINALIZE: begin
				cdin <= currentcacheline;
				ctagin <= {1'b0, ctag};
				oldtag <= {1'b0, ctag};
				if (ddr3rw == 1'b0) begin
					cwe <= 1'b1; // Do not forget to update cache
					busmode <= BUS_READ; // Back to read
				end else begin
					// NOTE: WRITE will always update cache line
					busmode <= BUS_WRITE; // Back to write
				end
			end

		endcase

	end

end

endmodule

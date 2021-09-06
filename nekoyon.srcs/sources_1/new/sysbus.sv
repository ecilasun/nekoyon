`timescale 1ns / 1ps

`include "cpuops.vh"

module sysbus(
	// Module control
	input wire wallclock,
	input wire spibaseclock,
	input wire cpuclock,
	input wire gpuclock,
	input wire videoclock,
	input wire reset,
	output logic businitialized = 1'b0,
	// CPU
	input wire ifetch, // High when fetching instructions, low otherwise
	input wire dcacheicachesync, // High when we need to flush D$ to memory
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
    // SPI
	output wire spi_cs_n,
	output wire spi_mosi,
	input wire spi_miso,
	output wire spi_sck,
	// DVI
	output wire [3:0] DVI_R,
	output wire [3:0] DVI_G,
	output wire [3:0] DVI_B,
	output wire DVI_HS,
	output wire DVI_VS,
	output wire DVI_DE,
	output wire DVI_CLK,
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
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0011 ? 1'b1 : 1'b0,	// 06: 0x8xxxxx0C SPI read/write port					+DEV_SPIRW
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0010 ? 1'b1 : 1'b0,	// 05: 0x8xxxxx08 UART read/write port					+DEV_UARTRW
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0001 ? 1'b1 : 1'b0,	// 04: 0x8xxxxx04 UART incoming queue byte available	+DEV_UARTBYTEAVAILABLE
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0000 ? 1'b1 : 1'b0,	// 03: 0x8xxxxx00 UART outgoing queue full				+DEV_UARTSENDFIFOFULL
	(busaddress[31:28]==4'b0011) ? 1'b1 : 1'b0,							// 02: 0x30000000 - 0x30010000 - P-RAM (64Kbytes)		+DEV_PRAM
	(busaddress[31:28]==4'b0010) ? 1'b1 : 1'b0,							// 02: 0x20000000 - 0x20010000 - G-RAM (64Kbytes)		+DEV_GRAM
	(busaddress[31:28]==4'b0001) ? 1'b1 : 1'b0,							// 01: 0x10000000 - 0x10010000 - S-RAM (64Kbytes)		+DEV_SRAM
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
	.clk10(wallclock),
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
// SPI
// ----------------------------------------------------------------------------

// SD Card Write FIFO
wire spiwfull, spiwempty, spiwvalid;
wire [7:0] spiwdout;
wire sddataoutready;
logic spiwre = 1'b0;
logic spiwwe = 1'b0;
logic [7:0] spiwdin;
SPIfifo SDCardWriteFifo(
	// In
	.full(spiwfull),
	.din(spiwdin),
	.wr_en(spiwwe),
	.wr_clk(cpuclock),
	// Out
	.empty(spiwempty),
	.dout(spiwdout),
	.rd_en(spiwre),
	.rd_clk(spibaseclock),
	.valid(spiwvalid),
	// Ctl
	.rst(reset) );

// Pull from write queue and send through SD controller
logic sddatawe = 1'b0;
logic [7:0] sddataout = 8'd0;
logic [1:0] sdqwritestate = 2'b00;
always @(posedge spibaseclock) begin

	spiwre <= 1'b0;
	sddatawe <= 1'b0;

	unique case (sdqwritestate)
		2'b00: begin
			if ((~spiwempty) & sddataoutready) begin
				spiwre <= 1'b1;
				sdqwritestate <= 2'b01;
			end
		end
		2'b01: begin
			if (spiwvalid) begin
				sddatawe <= 1'b1;
				sddataout <= spiwdout;
				sdqwritestate <= 2'b10;
			end
		end
		2'b10: begin
			// One clock delay to catch with sddataoutready properly
			sdqwritestate <= 2'b00;
		end
	endcase

end

// SD Card Read FIFO
wire spirempty, spirfull, spirvalid;
wire [7:0] spirdout;
logic [7:0] spirdin = 8'd0;
logic spirwe = 1'b0, spirre = 1'b0;
SPIfifo SDCardReadFifo(
	// In
	.full(spirfull),
	.din(spirdin),
	.wr_en(spirwe),
	.wr_clk(spibaseclock),
	// Out
	.empty(spirempty),
	.dout(spirdout),
	.rd_en(spirre),
	.valid(spirvalid),
	.rd_clk(cpuclock),
	// Ctl
	.rst(reset) );

// Push incoming data from SD controller to read queue
wire [7:0] sddatain;
wire sddatainready;
always @(posedge spibaseclock) begin
	spirwe <= 1'b0;
	if (sddatainready) begin
		spirwe <= 1'b1;
		spirdin <= sddatain;
	end
end

SPI_MASTER SPIMaster(
        .CLK(spibaseclock),
        .RST(reset),
        // SPI Master
        .SCLK(spi_sck),
        .CS_N(spi_cs_n),
        .MOSI(spi_mosi),
        .MISO(spi_miso),
        // Output from BUS
        .DIN_LAST(1'b0),
        .DIN_RDY(sddataoutready),	// can send now
        .DIN(sddataout),			// data to send
        .DIN_VLD(sddatawe),			// data write enable
        // Input to BUS
        .DOUT(sddatain),			// data arriving from SPI
        .DOUT_VLD(sddatainready) );	// data available for read

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
// S-RAM (64Kbytes, also acts as boot ROM) - Scratch Memory
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
// Color palette
// ----------------------------------------------------------------------------

wire palettewe;
wire [7:0] paletteaddress;
wire [7:0] palettereadaddress;
wire [23:0] palettedata;

logic [23:0] paletteentries[0:255];

// Set up with VGA color palette on startup
initial begin
	$readmemh("colorpalette.mem", paletteentries);
end

always @(posedge gpuclock) begin // Tied to GPU clock
	if (palettewe)
		paletteentries[paletteaddress] <= palettedata;
end

wire [23:0] paletteout;
assign paletteout = paletteentries[palettereadaddress];

// ----------------------------------------------------------------------------
// Video units and DVI scan-out
// ----------------------------------------------------------------------------

wire [3:0] gpu_vramwe;
wire [31:0] gpu_vramdin;
wire [16:0] gpu_vramaddr;


wire [11:0] video_x;
wire [11:0] video_y;

wire videopage;
wire [7:0] palette0;
wire [7:0] palette1;

wire dataEnable0, dataEnable1;
wire inDisplayWindow0, inDisplayWindow1;
wire [12:0] gpu_lanemask;

// when video page == 0, output comes from page 1
// when video page == 1, output comes from page 0

VideoControllerGen VMEMPage0(
	.gpuclock(gpuclock),
	.vgaclock(videoclock),
	.writesenabled(~videopage), // high when page==0
	.video_x(video_x),
	.video_y(video_y),
	// Wire input
	.memaddress(gpu_vramaddr[16:2]),
	.mem_writeena(gpu_vramwe),
	.writeword(gpu_vramdin),
	.lanemask(gpu_lanemask),
	// Video output
	.paletteindex(palette0),
	.dataEnable(dataEnable0),
	.inDisplayWindow(inDisplayWindow0) );

VideoControllerGen VMEMPage1(
	.gpuclock(gpuclock),
	.vgaclock(videoclock),
	.writesenabled(videopage), // high when page!=0
	.video_x(video_x),
	.video_y(video_y),
	// Wire input
	.memaddress(gpu_vramaddr[16:2]),
	.mem_writeena(gpu_vramwe),
	.writeword(gpu_vramdin),
	.lanemask(gpu_lanemask),
	// Video output
	.paletteindex(palette1),
	.dataEnable(dataEnable1),
	.inDisplayWindow(inDisplayWindow1) );

wire vsync_we;
wire [31:0] vsynccounter;
logic [31:0] vsyncID = 32'd0;

wire dataEnable = videopage == 1'b0 ? dataEnable1 : dataEnable0;
wire inDisplayWindow = videopage == 1'b0 ? inDisplayWindow1 : inDisplayWindow0;
assign DVI_DE = dataEnable;
assign palettereadaddress = (videopage == 1'b0) ? palette1 : palette0;

// TODO: Depending on video mode, use palette out or the byte itself (palette0/palette1) as RGB color
wire [3:0] VIDEO_B = /*vmode==1'b0 ? */paletteout[7:4];// : palette0[?:?];
wire [3:0] VIDEO_R = /*vmode==1'b0 ? */paletteout[15:12];// : palette0[?:?];
wire [3:0] VIDEO_G = /*vmode==1'b0 ? */paletteout[23:20];// : palette0[?:?];

// TODO: Add a border color register
assign DVI_R = inDisplayWindow ? (dataEnable ? VIDEO_R : 4'b0010) : 4'h0;
assign DVI_G = inDisplayWindow ? (dataEnable ? VIDEO_G : 4'b0010) : 4'h0;
assign DVI_B = inDisplayWindow ? (dataEnable ? VIDEO_B : 4'b0010) : 4'h0;
assign DVI_CLK = videoclock;

videosignalgen VideoScanOutUnit(
	.rst_i(reset),
	.clk_i(videoclock),					// Video clock input for 640x480 image
	.hsync_o(DVI_HS),				// DVI horizontal sync
	.vsync_o(DVI_VS),				// DVI vertical sync
	.counter_x(video_x),			// Video X position (in actual pixel units)
	.counter_y(video_y),			// Video Y position
	.vsynctrigger_o(vsync_we),		// High when we're OK to queue a VSYNC in FIFO
	.vsynccounter(vsynccounter) );	// Each vsync has a unique marker so that we can wait for them by name

// ----------------------------------------------------------------------------
// Domain crossing vsync
// ----------------------------------------------------------------------------

wire [31:0] vsync_fastdomain;
wire vsyncfifoempty;
wire vsyncfifovalid;

logic vsync_re;
DomainCrossSignalFifo GPUVGAVSyncQueue(
	.full(), // Not really going to get full (read clock faster than write clock)
	.din(vsynccounter),
	.wr_en(vsync_we),
	.empty(vsyncfifoempty),
	.dout(vsync_fastdomain),
	.rd_en(vsync_re),
	.wr_clk(videoclock),
	.rd_clk(gpuclock),
	.rst(reset),
	.valid(vsyncfifovalid) );

// Drain the vsync fifo and set a new vsync signal for the GPU every time we find one
// This is done in GPU clocks so we don't need to further sync the read data to GPU
always @(posedge gpuclock) begin
	vsync_re <= 1'b0;
	if (~vsyncfifoempty) begin
		vsync_re <= 1'b1;
	end
	if (vsyncfifovalid) begin
		vsyncID <= vsync_fastdomain;
	end
end

// ----------------------------------------------------------------------------
// GPU
// ----------------------------------------------------------------------------

wire gpu_gramre;
wire [3:0] gpu_gramwe;
wire [31:0] gpu_gramdin;
wire [15:0] gpu_gramaddr;
wire [31:0] gpu_gramdout;

wire gpu_pramre;
wire [3:0] gpu_pramwe;
wire [31:0] gpu_pramdin;
wire [15:0] gpu_pramaddr;
wire [31:0] gpu_pramdout;

gpu GPUDevice(
	.clock(gpuclock),
	.reset(reset),
	// vsync and video page control
	.vsyncID(vsyncID),
	.videopage(videopage),
	// V-RAM access (write only)
	.vramwe(gpu_vramwe),
	.vramdin(gpu_vramdin),
	.vramaddr(gpu_vramaddr),
	.lanemask(gpu_lanemask),
	// G-RAM access (read/write)
	.gramre(gpu_gramre),
	.gramwe(gpu_gramwe),
	.gramdin(gpu_gramdin),
	.gramaddr(gpu_gramaddr),
	.gramdout(gpu_gramdout),
	// P-RAM access (read/write)
	.pramre(gpu_pramre),
	.pramwe(gpu_pramwe),
	.pramdin(gpu_pramdin),
	.pramaddr(gpu_pramaddr),
	.pramdout(gpu_pramdout),
	// Color palette
	.palettewe(palettewe),
	.paletteaddress(paletteaddress),
	.palettedata(palettedata) );

// -----------------------------------------------------------------------
// G-RAM (64Kbytes) - Graphics Memory
// -----------------------------------------------------------------------

wire gramre = deviceSelect[`DEV_GRAM] ? busre : 1'b0;
wire [3:0] gramwe = deviceSelect[`DEV_GRAM] ? buswe : 4'h0;
wire [31:0] gramdin = deviceSelect[`DEV_GRAM] ? busdata : 32'd0;
wire [13:0] gramaddr = deviceSelect[`DEV_GRAM] ? busaddress[15:2] : 0;
wire [31:0] gramdout;

gpumemory GRAM(
	// Port A: CPU access
	.clka(cpuclock),
	.addra(gramaddr),
	.dina(gramdin),
	.douta(gramdout),
	.ena(deviceSelect[`DEV_GRAM] & (gramre | (|gramwe))),
	.wea(gramwe),
	// Port B: GPU access
	.clkb(gpuclock),
	.addrb(gpu_gramaddr[15:2]), // DWORD aligned
	.dinb(gpu_gramdin),
	.doutb(gpu_gramdout),
	.enb(gpu_gramre | (|gpu_gramwe)),
	.web(gpu_gramwe) );

// -----------------------------------------------------------------------
// P-RAM (32Kbytes) - Program Memory
// -----------------------------------------------------------------------

wire pramre = deviceSelect[`DEV_PRAM] ? busre : 1'b0;
wire [3:0] pramwe = deviceSelect[`DEV_PRAM] ? buswe : 4'h0;
wire [31:0] pramdin = deviceSelect[`DEV_PRAM] ? busdata : 32'd0;
wire [13:0] pramaddr = deviceSelect[`DEV_PRAM] ? busaddress[15:2] : 0;
wire [31:0] pramdout;

gpumemory PRAM(
	// Port A: CPU access
	.clka(cpuclock),
	.addra(pramaddr),
	.dina(pramdin),
	.douta(pramdout),
	.ena(deviceSelect[`DEV_PRAM] & (pramre | (|pramwe))),
	.wea(pramwe),
	// Port B: GPU access
	.clkb(gpuclock),
	.addrb(gpu_pramaddr[15:2]), // DWORD aligned
	.dinb(gpu_pramdin),
	.doutb(gpu_pramdout),
	.enb(gpu_pramre | (|gpu_pramwe)),
	.web(gpu_pramwe) );

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
logic [14:0] ctagreg;

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
localparam BUS_SPIRETIRE = 10;
localparam BUS_FLUSHDCACHE = 11;

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
				// Stop SPI writes
				spiwwe <= 1'b0;
				
				if (deviceSelect[`DEV_DDR3] & (busre | (|buswe))) begin
					currentcacheline <= cdout;
					oldtag <= ctagout;
					cdin <= cdout;
					ctagin <= ctagout;
					cwidemask <= {{8{buswe[3]}}, {8{buswe[2]}}, {8{buswe[1]}}, {8{buswe[0]}}};
					ddr3wdat <= busdata;
					ctagreg <= ctag;
				end else begin
					currentcacheline <= 256'd0;
					oldtag <= 16'd0;
					cdin <= 256'd0;
					ctagin <= 16'd0;
					cwidemask <= 32'd0;
					ddr3wdat <= 32'd0;
					ctagreg <= 15'd0;
				end

				if (|buswe) begin
					if (deviceSelect[`DEV_SPIRW])
						spiwdin <= busdata[7:0];
					busmode <= BUS_WRITE;
				end else if (busre) begin
					busmode <= BUS_READ;
				end else begin
					if (dcacheicachesync==1'b1)
						busmode <= BUS_FLUSHDCACHE; // all D$ gets dumped to memory, and marked 'clean'
					else
						busmode <= BUS_IDLE;
				end
			end
			
			BUS_FLUSHDCACHE: begin
				// TODO: Write back all of D$ to DDR3, mark tag[15] as 1'b0 (cache line clean)
				// cwe <= 1'b1;
				// for each cline
				//   ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b0, currentcacheline[127:0]};
				//   ddr3cmdwe <= 1'b1;
				//   ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b1, currentcacheline[255:128]};
				//   ddr3cmdwe <= 1'b1;
				//   ctagin[15] <= 1'b1;
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
							if (oldtag[14:0] == ctagreg) begin
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
									ddr3cmdin <= {1'b0, ctagreg, cline, 1'b0, 128'd0};
									ddr3cmdwe <= 1'b1;
									busmode <= BUS_DDR3CACHELOADHI;
								end
							end
						end
						deviceSelect[`DEV_SRAM]: begin
							dataout <= sramdout;
						end
						deviceSelect[`DEV_GRAM]: begin
							dataout <= gramdout;
						end
						deviceSelect[`DEV_PRAM]: begin
							dataout <= pramdout;
						end
						deviceSelect[`DEV_SPIRW]: begin
							if(~spirempty) begin
								spirre <= 1'b1;
								busmode <= BUS_SPIRETIRE;
							end else begin
								// Block when no data available
								// NOTE: SPI can't read without sending a data stream first
								busmode <= BUS_READ;
							end
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
						if (oldtag[14:0] == ctagreg) begin
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
								ddr3cmdin <= {1'b0, ctagreg, cline, 1'b0, 128'd0};
								ddr3cmdwe <= 1'b1;
								busmode <= BUS_DDR3CACHELOADHI;
							end
						end
					end
					deviceSelect[`DEV_SPIRW]: begin
						if (~spiwfull) begin
							spiwwe <= 1'b1;
							busmode <= BUS_IDLE;
						end else begin
							busmode <= BUS_WRITE;
						end
					end
					default: begin
						busmode <= BUS_IDLE;
					end
				endcase
			end
			
			BUS_SPIRETIRE: begin
				spirre <= 1'b0;
				if (spirvalid) begin
					dataout <= {spirdout, spirdout, spirdout, spirdout};
					busmode <= BUS_IDLE;
				end else begin
					busmode <= BUS_SPIRETIRE;
				end
			end

			BUS_DDR3CACHESTOREHI: begin
				ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b1, currentcacheline[255:128]}; // STOREHI
				ddr3cmdwe <= 1'b1;
				busmode <= BUS_DDR3CACHELOADLO;
			end

			BUS_DDR3CACHELOADLO: begin
				ddr3cmdin <= {1'b0, ctagreg, cline, 1'b0, 128'd0}; // LOADLO
				ddr3cmdwe <= 1'b1;
				busmode <= BUS_DDR3CACHELOADHI;
			end

			BUS_DDR3CACHELOADHI: begin
				ddr3cmdin <= {1'b0, ctagreg, cline, 1'b1, 128'd0}; // LOADHI
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
				ctagin <= {1'b0, ctagreg};
				oldtag <= {1'b0, ctagreg};
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

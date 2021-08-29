`timescale 1ns / 1ps

module ddr3driver(
	input wire sys_clk_in,
	input wire ddr3_ref,
	input wire cpuclock,
	input wire reset,
	output wire calib_done,
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

	output logic ddr3ready = 1'b0,
	output wire ddr3readvalid,
	output wire ddr3readempty,
	input wire ddr3readre,
	input wire ddr3cmdwe,
	input wire [152:0] ddr3cmdin,
	output wire [127:0] ddr3readout );

logic ddr3cmdre = 1'b0;
wire ddr3cmdfull, ddr3cmdempty, ddr3cmdvalid;
wire [152:0] ddr3cmdout;

wire [11:0] device_temp;

logic [27:0] app_addr = 28'd0;
logic [2:0]  app_cmd = 3'd0;
logic app_en = 1'b0;
wire app_rdy;

logic [127:0] app_wdf_data = 128'd0;
logic app_wdf_wren = 1'b0;
wire app_wdf_rdy;

wire [127:0] app_rd_data;
wire app_rd_data_end;
wire app_rd_data_valid;

wire app_sr_req = 0;
wire app_ref_req = 0;
wire app_zq_req = 0;
wire app_sr_active;
wire app_ref_ack;
wire app_zq_ack;

wire ddr3readfull;
logic ddr3readwe = 1'b0;
logic [127:0] ddr3readin = 128'd0;

wire ui_clk;
wire ui_clk_sync_rst;

DDR3MIG7 ddr3memoryinterface (
	// Physical device pins
   .ddr3_addr   (ddr3_addr),
   .ddr3_ba     (ddr3_ba),
   .ddr3_cas_n  (ddr3_cas_n),
   .ddr3_ck_n   (ddr3_ck_n),
   .ddr3_ck_p   (ddr3_ck_p),
   .ddr3_cke    (ddr3_cke),
   .ddr3_ras_n  (ddr3_ras_n),
   .ddr3_reset_n(ddr3_reset_n),
   .ddr3_we_n   (ddr3_we_n),
   .ddr3_dq     (ddr3_dq),
   .ddr3_dqs_n  (ddr3_dqs_n),
   .ddr3_dqs_p  (ddr3_dqs_p),
   .ddr3_cs_n   (ddr3_cs_n),
   .ddr3_dm     (ddr3_dm),
   .ddr3_odt    (ddr3_odt),

	// Device status
   .init_calib_complete (calib_done),
   .device_temp(device_temp),

   // User interface ports
   .app_addr 			(app_addr),
   .app_cmd 			(app_cmd),
   .app_en 				(app_en),
   .app_wdf_data		(app_wdf_data),
   .app_wdf_end			(app_wdf_wren),
   .app_wdf_wren		(app_wdf_wren),
   .app_rd_data			(app_rd_data),
   .app_rd_data_end 	(app_rd_data_end),
   .app_rd_data_valid	(app_rd_data_valid),
   .app_rdy 			(app_rdy),
   .app_wdf_rdy 		(app_wdf_rdy),
   .app_sr_req			(app_sr_req),
   .app_ref_req 		(app_ref_req),
   .app_zq_req 			(app_zq_req),
   .app_sr_active		(app_sr_active),
   .app_ref_ack 		(app_ref_ack),
   .app_zq_ack 			(app_zq_ack),
   .ui_clk				(ui_clk),
   .ui_clk_sync_rst 	(ui_clk_sync_rst),
   .app_wdf_mask		(16'h0000), // WARNING: Active low, and always set to write all DWORDs

   // Clock and Reset input ports
   .sys_clk_i 			(sys_clk_in),
   .clk_ref_i			(ddr3_ref),
   .sys_rst				(~reset) );

localparam IDLE = 3'd0;
localparam DECODECMD = 3'd1;
localparam WRITE = 3'd2;
localparam WRITE_DONE = 3'd3;
localparam READ = 3'd4;
localparam READ_DONE = 3'd5;

logic [2:0] ddr3uistate = IDLE;

localparam CMD_WRITE = 3'b000;
localparam CMD_READ = 3'b001;

// Bus calibration complete trigger
always @ (posedge cpuclock) begin
	if (calib_done)
		ddr3ready <= 1'b1;
end

// ddr3 driver
always @ (posedge ui_clk) begin
	if (ui_clk_sync_rst) begin
		ddr3uistate <= IDLE;
		app_en <= 0;
		app_wdf_wren <= 0;
	end else begin

		case (ddr3uistate)

			IDLE: begin
				ddr3readwe <= 1'b0;
				if (~ddr3cmdempty) begin
					ddr3cmdre <= 1'b1;
					ddr3uistate <= DECODECMD;
				end
			end

			DECODECMD: begin
				ddr3cmdre <= 1'b0;
				if (ddr3cmdvalid) begin
					if (ddr3cmdout[152]==1'b1) begin // Write request?
						if (app_rdy & app_wdf_rdy) begin
							// Take early opportunity to write
							app_en <= 1;
							app_wdf_wren <= 1;
							app_addr <= {1'b0, ddr3cmdout[151:128], 3'b000}; // Addresses are in multiples of 16 bits x8 == 128 bits, top bit is supposed to stay zero
							app_cmd <= CMD_WRITE;
							app_wdf_data <= ddr3cmdout[127:0]; // 128bit value to write to memory from cache
							ddr3uistate <= WRITE_DONE;
						end else
							ddr3uistate <= WRITE;
					end else begin
						if (app_rdy) begin
							// Take early opportunity to read
							app_en <= 1;
							app_addr <= {1'b0, ddr3cmdout[151:128], 3'b000}; // Addresses are in multiples of 16 bits x8 == 128 bits, top bit is supposed to stay zero
							app_cmd <= CMD_READ;
							ddr3uistate <= READ_DONE;
						end else
							ddr3uistate <= READ;
					end
				end
			end

			WRITE: begin
				if (app_rdy & app_wdf_rdy) begin
					app_en <= 1;
					app_wdf_wren <= 1;
					app_addr <= {1'b0, ddr3cmdout[151:128], 3'b000}; // Addresses are in multiples of 16 bits x8 == 128 bits, top bit is supposed to stay zero
					app_cmd <= CMD_WRITE;
					app_wdf_data <= ddr3cmdout[127:0]; // 128bit value to write to memory from cache
					ddr3uistate <= WRITE_DONE;
				end
			end

			WRITE_DONE: begin
				if (app_rdy & app_en) begin
					app_en <= 0;
				end
			
				if (app_wdf_rdy & app_wdf_wren) begin
					app_wdf_wren <= 0;
				end
			
				if (~app_en & ~app_wdf_wren) begin
					ddr3uistate <= IDLE;
				end
			end

			READ: begin
				if (app_rdy) begin
					app_en <= 1;
					app_addr <= {1'b0, ddr3cmdout[151:128], 3'b000}; // Addresses are in multiples of 16 bits x8 == 128 bits, top bit is supposed to stay zero
					app_cmd <= CMD_READ;
					ddr3uistate <= READ_DONE;
				end
			end

			READ_DONE: begin
				if (app_rdy & app_en) begin
					app_en <= 0;
				end

				if (app_rd_data_valid) begin
					// After this step, full 128bit value will be available on the
					// ddr3readre when read is asserted and ddr3readvalid is high
					ddr3readwe <= 1'b1;
					ddr3readin <= app_rd_data;
					ddr3uistate <= IDLE;
				end
			end
			
			default: begin
				ddr3uistate <= IDLE;
			end
		endcase
	end
end

// Command fifo
ddr3cmdfifo DDR3Cmd(
	.full(ddr3cmdfull),
	.din(ddr3cmdin),
	.wr_en(ddr3cmdwe),
	.wr_clk(cpuclock),
	.empty(ddr3cmdempty),
	.dout(ddr3cmdout),
	.rd_en(ddr3cmdre),
	.valid(ddr3cmdvalid),
	.rd_clk(ui_clk),
	.rst(reset) );

// Read done queue
ddr3readdonequeue DDR3ReadDone(
	.full(ddr3readfull),
	.din(ddr3readin),
	.wr_en(ddr3readwe),
	.wr_clk(ui_clk),
	.empty(ddr3readempty),
	.dout(ddr3readout),
	.rd_en(ddr3readre),
	.valid(ddr3readvalid),
	.rd_clk(cpuclock),
	.rst(ui_clk_sync_rst) );

endmodule

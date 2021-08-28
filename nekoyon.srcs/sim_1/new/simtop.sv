`timescale 1ns / 1ps

module simtop(
    );

logic fpgaexternalclock;
wire uart_rxd_out;
logic uart_txd_in = 1'b0;

initial begin
	fpgaexternalclock = 1'b0;
	$display("NekoYon started up");
end

topmodule topinst(
	.sys_clock(fpgaexternalclock),
	.uart_rxd_out(uart_rxd_out),
	.uart_txd_in(uart_txd_in) );

// External clock ticks at 100Mhz
always begin
	#5 fpgaexternalclock = ~fpgaexternalclock;
end

endmodule

`timescale 1ns / 1ps

// -----------------------------------------------------------------------
// CPU
// -----------------------------------------------------------------------

module cpu(
	input wire clock,
	input wire wallclock,
	input wire reset,
	input wire businitialized,
	input wire busbusy,
	input wire irqtrigger,
	input wire [3:0] irqlines,
	output logic ifetch = 1'b0,
	output logic [31:0] busaddress = 32'd0,
	inout wire [31:0] busdata,
	output logic [3:0] buswe = 4'h0,
	output logic busre = 1'b0 );

// -----------------------------------------------------------------------
// Bidirectional bus logic
// -----------------------------------------------------------------------

logic [31:0] dataout = 32'd0;
assign busdata = (|buswe) ? dataout : 32'dz;

// -----------------------------------------------------------------------
// Internal states
// -----------------------------------------------------------------------

logic [31:0] PC;
logic [31:0] nextPC;
logic [31:0] instruction;
logic ebreak;
logic ecall;
logic illegalinstruction;
logic [31:0] mathresult;

localparam CPU_RESET		= 0;
localparam CPU_RETIRE		= 1;
localparam CPU_FETCH		= 2;
localparam CPU_DECODE		= 3;
localparam CPU_EXEC			= 4;
localparam CPU_LOAD			= 5;
localparam CPU_UPDATECSR	= 6;
localparam CPU_TRAP			= 7;
localparam CPU_MSTALL		= 8;
localparam CPU_WBMRESULT	= 9;

logic [9:0] cpumode;

logic [31:0] immreach;
logic [31:0] immpc;
logic [31:0] pc4;
logic [31:0] branchpc;

wire [18:0] instrOneHot;
wire [3:0] aluop;
wire [3:0] bluop;
wire [2:0] func3;
wire [6:0] func7;
wire [11:0] func12;
wire [4:0] rs1;
wire [4:0] rs2;
wire [4:0] rs3;
wire [4:0] rd;
wire [4:0] csrindex;
wire [31:0] immed;
wire selectimmedasrval2;

wire [31:0] rval1;
wire [31:0] rval2;
logic rwe = 1'b0;
logic [31:0] rdin;

wire [31:0] aluout;
wire branchout;

logic [31:0] CSRReg [0:`CSR_REGISTER_COUNT-1];

logic [63:0] internalcyclecounter = 64'd0;
logic [63:0] internalwallclockcounter = 64'd0;
logic [63:0] internalwallclockcounter1 = 64'd0;
logic [63:0] internalwallclockcounter2 = 64'd0;
logic [63:0] internaltimecmp = 64'd0;
logic timertrigger = 1'b0;
logic [63:0] internalretirecounter = 64'd0;
logic timerinterrupt = 1'b0;
logic externalinterrupt = 1'b0;
logic [31:0] mepc = 32'd0;
logic [31:0] csrread = 32'd0;
logic [31:0] lastinstruction = 32'd0;

// -----------------------------------------------------------------------
// Integer register file and misc wires
// -----------------------------------------------------------------------

registerfile IntegerRegFile(
	.clock(clock),
	.rs1(rs1),
	.rs2(rs2),
	.rd(rd),
	.wren(rwe), 
	.datain(rdin),
	.rval1(rval1),
	.rval2(rval2) );

// -----------------------------------------------------------------------
// Decoder
// -----------------------------------------------------------------------

decoder InstructionDecoder(
	.instruction(instruction),
	.instrOneHot(instrOneHot),
	.aluop(aluop),
	.bluop(bluop),
	.func3(func3),
	.func7(func7),
	.func12(func12),
	.rs1(rs1),
	.rs2(rs2),
	.rs3(rs3),
	.rd(rd),
	.csrindex(csrindex),
	.immed(immed),
	.selectimmedasrval2(selectimmedasrval2) );

// -----------------------------------------------------------------------
// Integer ALU
// -----------------------------------------------------------------------

IALU IntegerALU(
	.aluout(aluout),
	.func3(func3),
	.val1(rval1),
	.val2(selectimmedasrval2 ? immed : rval2),
	.aluop(aluop) );

// -----------------------------------------------------------------------
// Branch ALU
// -----------------------------------------------------------------------

BALU BranchALU(
	.branchout(branchout),
	.val1(rval1),
	.val2(rval2),
	.bluop(bluop) );

// -----------------------------------------------------------------------
// Address generation
// -----------------------------------------------------------------------

always_comb begin
	immreach = rval1 + immed;
	immpc = PC + immed;
	pc4 = PC + 32'd4;
	branchpc = branchout ? (PC + immed) : (PC + 32'd4);
end

// -----------------------------------------------------------------------
// Integer mul/div/rem units
// -----------------------------------------------------------------------

wire mulbusy, divbusy, divbusyu;
wire [31:0] product;
wire [31:0] quotient;
wire [31:0] quotientu;
wire [31:0] remainder;
wire [31:0] remainderu;

wire isexecuting = (cpumode[CPU_EXEC]==1'b1) ? 1'b1 : 1'b0;
wire mulstart = isexecuting & (aluop==`ALU_MUL) & (instrOneHot[`O_H_OP]);
wire divstart = isexecuting & (aluop==`ALU_DIV | aluop==`ALU_REM) & (instrOneHot[`O_H_OP]);

logic [31:0] dividend = 32'd0;
logic [31:0] divisor = 32'd1;
logic [31:0] multiplicand = 32'd0;
logic [31:0] multiplier = 32'd0;

multiplier themul(
    .clk(clock),
    .reset(reset),
    .start(mulstart),
    .busy(mulbusy),           // calculation in progress
    .func3(func3),
    .multiplicand(multiplicand),
    .multiplier(multiplier),
    .product(product) );

DIVU unsigneddivider (
	.clk(clock),
	.reset(reset),
	.start(divstart),		// start signal
	.busy(divbusyu),		// calculation in progress
	.dividend(dividend),	// dividend
	.divisor(divisor),		// divisor
	.quotient(quotientu),	// result: quotient
	.remainder(remainderu)	// result: remainer
);

DIV signeddivider (
	.clk(clock),
	.reset(reset),
	.start(divstart),		// start signal
	.busy(divbusy),			// calculation in progress
	.dividend(dividend),		// dividend
	.divisor(divisor),		// divisor
	.quotient(quotient),	// result: quotient
	.remainder(remainder)	// result: remainder
);

// Start trigger
wire imathstart = divstart | mulstart;

// Stall status
wire imathbusy = divbusy | divbusyu | mulbusy;

// -----------------------------------------------------------------------
// Cycle/Timer/Reti CSRs
// -----------------------------------------------------------------------

// See https://cv32e40p.readthedocs.io/en/latest/control_status_registers/#cs-registers for defaults
initial begin
	CSRReg[`CSR_UNUSED]		= 32'd0;
	CSRReg[`CSR_FFLAGS]		= 32'd0;
	CSRReg[`CSR_FRM]		= 32'd0;
	CSRReg[`CSR_FCSR]		= 32'd0;
	CSRReg[`CSR_MSTATUS]	= 32'h00001800; // MPP (machine previous priviledge mode 12:11) hardwired to 2'b11 on startup
	CSRReg[`CSR_MISA]		= {2'b01, 4'b0000, 26'b00000000000001000100100000};	// 301 MXL:1, 32 bits, Extensions: I M F;
	CSRReg[`CSR_MIE]		= 32'd0;
	CSRReg[`CSR_MTVEC]		= 32'd0;
	CSRReg[`CSR_MSCRATCH]	= 32'd0;
	CSRReg[`CSR_MEPC]		= 32'd0;
	CSRReg[`CSR_MCAUSE]		= 32'd0;
	CSRReg[`CSR_MTVAL]		= 32'd0;
	CSRReg[`CSR_MIP]		= 32'd0;
	CSRReg[`CSR_DCSR]		= 32'h40000003;
	CSRReg[`CSR_DPC]		= 32'd0;
	CSRReg[`CSR_TIMECMPLO]	= 32'hFFFFFFFF; // timecmp = 0xFFFFFFFFFFFFFFFF
	CSRReg[`CSR_TIMECMPHI]	= 32'hFFFFFFFF;
	CSRReg[`CSR_CYCLELO]	= 32'd0;
	CSRReg[`CSR_CYCLEHI]	= 32'd0;
	CSRReg[`CSR_TIMELO]		= 32'd0;
	CSRReg[`CSR_RETILO]		= 32'd0;
	CSRReg[`CSR_TIMEHI]		= 32'd0;
	CSRReg[`CSR_RETIHI]		= 32'd0;
	CSRReg[`CSR_HARTID]		= 32'd0;
	// TODO: mvendorid: 0x0000_0602
	// TODO: marchid: 0x0000_0004
end

// Other custom CSRs r/w between 0x802-0x8FF

// Advancing cycles is simple since clocks = cycles
always @(posedge clock) begin
	internalcyclecounter <= internalcyclecounter + 64'd1;
end

// Time is also simple since we know we have 25M ticks per second
// from which we can derive seconds elapsed
always @(posedge wallclock) begin
	internalwallclockcounter <= internalwallclockcounter + 64'd1;
end
// Small adjustment to bring wallclock counter closer to cpu clock domain
always @(posedge clock) begin
	internalwallclockcounter1 <= internalwallclockcounter;
	internalwallclockcounter2 <= internalwallclockcounter1;
	timertrigger <= (internalwallclockcounter2 >= internaltimecmp) ? 1'b1 : 1'b0;
end

// Retired instruction counter
always @(posedge clock) begin
	if (cpumode[CPU_RETIRE])
		internalretirecounter <= internalretirecounter + 64'd1;
end

// -----------------------------------------------------------------------
// Core
// -----------------------------------------------------------------------

always @(posedge clock) begin

	if (reset) begin

		cpumode <= 0;
		cpumode[CPU_RESET] <= 1'b1;

	end else begin

		cpumode <= 0;

		case (1'b1)

			cpumode[CPU_RESET]: begin
				PC <= `CPU_RESET_VECTOR;
				nextPC <= `CPU_RESET_VECTOR;
				cpumode[CPU_RETIRE] <= 1'b1;
			end

			cpumode[CPU_FETCH]: begin
				busre <= 1'b0;
				if (busbusy) begin
					cpumode[CPU_FETCH] <= 1'b1;
				end else begin
					instruction <= busdata;
					lastinstruction <= busdata;

					// Trigger interrupts
					timerinterrupt <= CSRReg[`CSR_MIE][7] & timertrigger;
					externalinterrupt <= (CSRReg[`CSR_MIE][11] & irqtrigger);

					// Update CSRs with internal counters
					{CSRReg[`CSR_CYCLEHI], CSRReg[`CSR_CYCLELO]} <= internalcyclecounter;
					{CSRReg[`CSR_TIMEHI], CSRReg[`CSR_TIMELO]} <= internalwallclockcounter2;
					{CSRReg[`CSR_RETIHI], CSRReg[`CSR_RETILO]} <= internalretirecounter;

					// Update internal structures with CSRs
					mepc <= CSRReg[`CSR_MEPC];

					cpumode[CPU_DECODE] <= 1'b1;
				end
			end

			cpumode[CPU_DECODE]: begin
				nextPC <= pc4;
				// D$ mode
				ifetch <= 1'b0;
				ebreak <= 1'b0;
				ecall <= 1'b0;
				illegalinstruction <= 1'b0;
				rdin <= 32'd0;

				// Take load or op branch, otherwise process store in-place
				if (instrOneHot[`O_H_LOAD] | instrOneHot[`O_H_FLOAT_LDW]) begin
					busaddress <= immreach;
					busre <= 1'b1;
					cpumode[CPU_LOAD] <= 1'b1;
				end else if (instrOneHot[`O_H_STORE] | instrOneHot[`O_H_FLOAT_STW]) begin
					busaddress <= immreach;
					case (func3)
						3'b000: begin // BYTE
							dataout <= {rval2[7:0], rval2[7:0], rval2[7:0], rval2[7:0]};
							case (immreach[1:0])
								2'b11: begin buswe <= 4'h8; end
								2'b10: begin buswe <= 4'h4; end
								2'b01: begin buswe <= 4'h2; end
								2'b00: begin buswe <= 4'h1; end
							endcase
						end
						3'b001: begin // WORD
							dataout <= {rval2[15:0], rval2[15:0]};
							case (immreach[1])
								1'b1: begin buswe <= 4'hC; end
								1'b0: begin buswe <= 4'h3; end
							endcase
						end
						default: begin // DWORD
							dataout <= /*(instrOneHot[`O_H_FLOAT_STW]) ? frval2 :*/ rval2;
							buswe <= 4'hF;
						end
					endcase
					cpumode[CPU_RETIRE] <= 1'b1;
				end else if (instrOneHot[`O_H_SYSTEM]) begin
					case (func3)
						// ECALL/EBREAK
						3'b000: begin
							case (func12)
								12'b0000000_00000: begin // ECALL
									// OS service call
									// eg: li a7, 93 -> terminate application
									ecall <= CSRReg[`CSR_MIE][3];
								end
								12'b0000000_00001: begin // EBREAK
									ebreak <= CSRReg[`CSR_MIE][3];
								end
								/*12'b0000000_00101: begin // WFI
									// NOOP for single core
								end
								12'b0001001_?????: begin // SFENCE.VMA
									// NOT IMPLEMENTED
								end*/
								// privileged instructions
								12'b0011000_00010: begin // MRET
									// MACHINE MODE
									if (CSRReg[`CSR_MCAUSE][15:0] == 16'd3) CSRReg[`CSR_MIP][3] <= 1'b0;	// Disable machine software interrupt pending
									if (CSRReg[`CSR_MCAUSE][15:0] == 16'd7) CSRReg[`CSR_MIP][7] <= 1'b0;	// Disable machine timer interrupt pending
									if (CSRReg[`CSR_MCAUSE][15:0] == 16'd11) CSRReg[`CSR_MIP][11] <= 1'b0;	// Disable machine external interrupt pending
									CSRReg[`CSR_MSTATUS][3] <= CSRReg[`CSR_MSTATUS][7];						// MIE=MPIE - set to previous machine interrupt enable state
									CSRReg[`CSR_MSTATUS][7] <= 1'b0;										// Clear MPIE
									nextPC <= mepc;
								end
								/*12'b0001000_00010: begin // SRET
									// SUPERVISOR MODE NOT IMPLEMENTED
								end
								12'b0000000_00010: begin // URET
									// USER MORE NOT IMPLEMENTED
								end*/
								default: begin
									// All other cases act as NOOP (WFI also drops here)
								end
							endcase
							cpumode[CPU_RETIRE] <= 1'b1;
						end
						// CSRRW/CSRRS/CSSRRC/CSRRWI/CSRRSI/CSRRCI
						3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: begin 
							csrread <= CSRReg[csrindex];
							cpumode[CPU_UPDATECSR] <= 1'b1;
						end
						// Unknown
						default: begin
							cpumode[CPU_RETIRE] <= 1'b1;
						end
					endcase
				end else begin
					// Pre-arrange math inputs
					dividend <= rval1;
					divisor <= rval2;
					multiplicand <= rval1;
					multiplier <= rval2;
					cpumode[CPU_EXEC] <= 1'b1;
				end
			end

			cpumode[CPU_LOAD]: begin
				busre <= 1'b0;
				if (busbusy) begin
					cpumode[CPU_LOAD] <= 1'b1;
				end else begin
					/*if (instrOneHot[`O_H_FLOAT_LDW]) begin
						frwe <= 1'b1;
					end else begin*/
						rwe <= 1'b1;
					/*end*/
					case (func3)
						3'b000: begin // BYTE with sign extension
							case (busaddress[1:0])
								2'b11: begin rdin <= {{24{busdata[31]}}, busdata[31:24]}; end
								2'b10: begin rdin <= {{24{busdata[23]}}, busdata[23:16]}; end
								2'b01: begin rdin <= {{24{busdata[15]}}, busdata[15:8]}; end
								2'b00: begin rdin <= {{24{busdata[7]}},  busdata[7:0]}; end
							endcase
						end
						3'b001: begin // WORD with sign extension
							case (busaddress[1])
								1'b1: begin rdin <= {{16{busdata[31]}}, busdata[31:16]}; end
								1'b0: begin rdin <= {{16{busdata[15]}}, busdata[15:0]}; end
							endcase
						end
						3'b010: begin // DWORD
							/*if (instrOneHot[`O_H_FLOAT_LDW])
								fregdata <= busdata[31:0];
							else*/
								rdin <= busdata[31:0];
						end
						3'b100: begin // BYTE with zero extension
							case (busaddress[1:0])
								2'b11: begin rdin <= {24'd0, busdata[31:24]}; end
								2'b10: begin rdin <= {24'd0, busdata[23:16]}; end
								2'b01: begin rdin <= {24'd0, busdata[15:8]}; end
								2'b00: begin rdin <= {24'd0, busdata[7:0]}; end
							endcase
						end
						3'b101: begin // WORD with zero extension
							case (busaddress[1])
								1'b1: begin rdin <= {16'd0, busdata[31:16]}; end
								1'b0: begin rdin <= {16'd0, busdata[15:0]}; end
							endcase
						end
					endcase
					cpumode[CPU_RETIRE] <= 1'b1;
				end
			end

			cpumode[CPU_EXEC]: begin
				if ((instrOneHot[`O_H_OP] || instrOneHot[`O_H_OP_IMM]) && imathstart)
					cpumode[CPU_MSTALL] <= 1'b1;
				else
					cpumode[CPU_RETIRE] <= 1'b1;

				case (1'b1)
					instrOneHot[`O_H_AUPC]: begin
						rwe <= 1'b1;
						rdin <= immpc;
					end
					instrOneHot[`O_H_LUI]: begin
						rwe <= 1'b1;
						rdin <= immed;
					end
					instrOneHot[`O_H_JAL]: begin
						rwe <= 1'b1;
						rdin <= pc4;
						nextPC <= immpc;
					end
					instrOneHot[`O_H_OP], instrOneHot[`O_H_OP_IMM]: begin
						if (~imathstart) begin
							rwe <= 1'b1;
							rdin <= aluout;
						end
					end
					instrOneHot[`O_H_FLOAT_OP]: begin
						// TBD
					end
					instrOneHot[`O_H_FLOAT_MADD], instrOneHot[`O_H_FLOAT_MSUB], instrOneHot[`O_H_FLOAT_NMSUB], instrOneHot[`O_H_FLOAT_NMADD]: begin
						// TBD
					end
					instrOneHot[`O_H_FENCE]: begin
						// TBD
					end
					instrOneHot[`O_H_JALR]: begin
						rwe <= 1'b1;
						rdin <= pc4;
						nextPC <= immreach;
					end
					instrOneHot[`O_H_BRANCH]: begin
						nextPC <= branchpc;
					end
					instrOneHot[`O_H_CUSTOM]: begin
						// TODO: Some custom extensions will go in here
					end
					default: begin
						illegalinstruction <= CSRReg[`CSR_MIE][3];
					end
				endcase
			end
			
			cpumode[CPU_MSTALL]: begin
				if (imathbusy) begin
					// Keep stalling while M/D/R units are busy
					cpumode[CPU_MSTALL] <= 1'b1;
				end else begin
					unique case (aluop)
						`ALU_MUL: begin
							mathresult <= product;
						end
						`ALU_DIV: begin
							mathresult <= func3==`F3_DIV ? quotient : quotientu;
						end
						`ALU_REM: begin
							mathresult <= func3==`F3_REM ? remainder : remainderu;
						end
					endcase
					cpumode[CPU_WBMRESULT] <= 1'b1;
				end
			end

			cpumode[CPU_WBMRESULT]: begin
				rwe <= 1'b1;
				rdin <= mathresult;
				cpumode[CPU_RETIRE] <= 1'b1;
			end

			cpumode[CPU_UPDATECSR]: begin
				// Save previous value to destination register
				rwe <= 1'b1;
				rdin <= csrread;

				// Write to r/w CSR
				case(func3)
					3'b001: begin // CSRRW
						CSRReg[csrindex] <= rval1;
					end
					3'b101: begin // CSRRWI
						CSRReg[csrindex] <= immed;
					end
					3'b010: begin // CSRRS
						CSRReg[csrindex] <= csrread | rval1;
					end
					3'b110: begin // CSRRSI
						CSRReg[csrindex] <= csrread | immed;
					end
					3'b011: begin // CSSRRC
						CSRReg[csrindex] <= csrread & (~rval1);
					end
					3'b111: begin // CSRRCI
						CSRReg[csrindex] <= csrread & (~immed);
					end
					default: begin // Unknown
						CSRReg[csrindex] <= csrread;
					end
				endcase
				cpumode[CPU_RETIRE] <= 1'b1;
			end
			
			cpumode[CPU_TRAP]: begin
				// Common action in case of 'any' interrupt
				CSRReg[`CSR_MSTATUS][7] <= CSRReg[`CSR_MSTATUS][3]; // Remember interrupt enable status in pending state (MPIE = MIE)
				CSRReg[`CSR_MSTATUS][3] <= 1'b0; // Clear interrupts during handler
				CSRReg[`CSR_MTVAL] <= PC; // Store last known program counter
				CSRReg[`CSR_MSCRATCH] <= lastinstruction; // Store the offending instruction for IEX
				CSRReg[`CSR_MEPC] <= mepc; // Remember where to return (special case; ebreak returns to same PC as breakpoint)

				// Jump to handler
				// Set up non-vectored branch if lower 2 bits of MTVEC are 2'b00 (Direct mode)
				// Set up vectored branch if lower 2 bits of MTVEC are 2'b01 (Vectored mode)
				case (CSRReg[`CSR_MTVEC][1:0])
					2'b00: begin
						// Direct
						PC <= {CSRReg[`CSR_MTVEC][31:2], 2'b00};
						busaddress <= {CSRReg[`CSR_MTVEC][31:2], 2'b00};
					end
					2'b01: begin
						// Vectored
						// Exceptions: MTVEC
						// Interrupts: MTVEC+4*MCAUSE
						case (1'b1)
							illegalinstruction, ebreak, ecall: begin
								// Use BASE only
								PC <= {CSRReg[`CSR_MTVEC][31:2], 2'b00};
								busaddress <= {CSRReg[`CSR_MTVEC][31:2], 2'b00};
							end
							timerinterrupt: begin
								PC <= {CSRReg[`CSR_MTVEC][31:2], 2'b00} + 32'h1C;
								busaddress <= {CSRReg[`CSR_MTVEC][31:2], 2'b00} + 32'h1C; // 4*7
							end
							externalinterrupt: begin
								PC <= {CSRReg[`CSR_MTVEC][31:2], 2'b00} + 32'h2C;
								busaddress <= {CSRReg[`CSR_MTVEC][31:2], 2'b00} + 32'h2C; // 4*11
							end
						endcase
					end
				endcase
				busre <= 1'b1;

				// Set interrupt pending bits
				// NOTE: illegal instruction and ebreak both create the same machine software interrupt
				{CSRReg[`CSR_MIP][3], CSRReg[`CSR_MIP][7], CSRReg[`CSR_MIP][11]} <= {illegalinstruction | ebreak | ecall, timerinterrupt, externalinterrupt};

				case (1'b1)
					illegalinstruction, ebreak, ecall: begin
						CSRReg[`CSR_MCAUSE][15:0] <= 16'd3; // Illegal instruction or breakpoint interrupt
						CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 12'd0, ecall, ebreak, illegalinstruction};
					end
					timerinterrupt: begin // NOTE: Time interrupt stays pending until cleared
						CSRReg[`CSR_MCAUSE][15:0] <= 16'd7; // Timer Interrupt
						CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 15'd0}; // Type of timer interrupt is set to zero
					end
					externalinterrupt: begin
						CSRReg[`CSR_MCAUSE][15:0] <= 16'd11; // Machine External Interrupt
						// Device mask (lower 15 bits of upper word)
						// [11:0]:SWITCHES:SPIRX:UARTRX
						CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 11'd0, irqlines};
					end
					default: begin
						CSRReg[`CSR_MCAUSE][15:0] <= 16'd0; // No interrupt/exception
						CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 15'd0};
					end
				endcase
				
				cpumode[CPU_FETCH] <= 1'b1;
			end

			cpumode[CPU_RETIRE]: begin
				// Stop memory reads/writes
				buswe <= 1'b0;
				busre <= 1'b0;

				// Stop register writes
				rwe <= 1'b0;

				if (busbusy) begin
					cpumode[CPU_RETIRE] <= 1'b1;
				end else begin
					// I$ mode
					ifetch <= 1'b1;

					// Copy CSR states to internal registers
					internaltimecmp <= {CSRReg[`CSR_TIMECMPHI], CSRReg[`CSR_TIMECMPLO]};

					if (CSRReg[`CSR_MSTATUS][3] & (illegalinstruction | ebreak | ecall | timerinterrupt | externalinterrupt)) begin
						mepc <= ebreak ? PC : nextPC;
						cpumode[CPU_TRAP] <= 1'b1;
					end else begin
						PC <= nextPC;
						busaddress <= nextPC;
						busre <= 1'b1;
						cpumode[CPU_FETCH] <= 1'b1;
					end
				end
			end

		endcase
	end

end

endmodule

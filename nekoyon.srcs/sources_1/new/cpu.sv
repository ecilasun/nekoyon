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
	output logic busre = 1'b0,
	output logic dcacheicachesync = 1'b0);

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
localparam CPU_FPU			= 5;
localparam CPU_LOAD			= 6;
localparam CPU_UPDATECSR	= 7;
localparam CPU_TRAP			= 8;
localparam CPU_MSTALL		= 9;
localparam CPU_WBMRESULT	= 10;
localparam CPU_FSTALL		= 11;
localparam CPU_FMSTALL		= 12;

logic [12:0] cpumode;

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
wire [31:0] frval1;
wire [31:0] frval2;
wire [31:0] frval3;
logic rwe = 1'b0;
logic frwe = 1'b0;
logic [31:0] rdin;
logic [31:0] frdin;

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

// -----------------------------------------------------------------------
// Integer register file
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
// Float register file
// -----------------------------------------------------------------------

floatregisterfile FloatRegFile(
	.clock(clock),
	.rs1(rs1),
	.rs2(rs2),
	.rs3(rs3),
	.rd(rd),
	.wren(frwe), 
	.datain(frdin),
	.rval1(frval1),
	.rval2(frval2),
	.rval3(frval3) );

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
// FPU
// -----------------------------------------------------------------------

logic fmaddvalid = 1'b0;
logic fmsubvalid = 1'b0;
logic fnmsubvalid = 1'b0;
logic fnmaddvalid = 1'b0;
logic faddvalid = 1'b0;
logic fsubvalid = 1'b0;
logic fmulvalid = 1'b0;
logic fdivvalid = 1'b0;
logic fi2fvalid = 1'b0;
logic fui2fvalid = 1'b0;
logic ff2ivalid = 1'b0;
logic ff2uivalid = 1'b0;
logic fsqrtvalid = 1'b0;
logic feqvalid = 1'b0;
logic fltvalid = 1'b0;
logic flevalid = 1'b0;

wire fmaddresultvalid;
wire fmsubresultvalid;
wire fnmsubresultvalid; 
wire fnmaddresultvalid;

wire faddresultvalid;
wire fsubresultvalid;
wire fmulresultvalid;
wire fdivresultvalid;
wire fi2fresultvalid;
wire fui2fresultvalid;
wire ff2iresultvalid;
wire ff2uiresultvalid;
wire fsqrtresultvalid;
wire feqresultvalid;
wire fltresultvalid;
wire fleresultvalid;

wire [31:0] fmaddresult;
wire [31:0] fmsubresult;
wire [31:0] fnmsubresult;
wire [31:0] fnmaddresult;
wire [31:0] faddresult;
wire [31:0] fsubresult;
wire [31:0] fmulresult;
wire [31:0] fdivresult;
wire [31:0] fi2fresult;
wire [31:0] fui2fresult;
wire [31:0] ff2iresult;
wire [31:0] ff2uiresult;
wire [31:0] fsqrtresult;
wire [7:0] feqresult;
wire [7:0] fltresult;
wire [7:0] fleresult;

fp_madd floatfmadd(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmaddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmaddvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fmaddvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmaddresult),
	.m_axis_result_tvalid(fmaddresultvalid) );

fp_msub floatfmsub(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmsubvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fmsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmsubresult),
	.m_axis_result_tvalid(fmsubresultvalid) );

fp_madd floatfnmsub(
	.s_axis_a_tdata({~frval1[31], frval1[30:0]}), // -A
	.s_axis_a_tvalid(fnmsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fnmsubvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fnmsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fnmsubresult),
	.m_axis_result_tvalid(fnmsubresultvalid) );

fp_msub floatfnmadd(
	.s_axis_a_tdata({~frval1[31], frval1[30:0]}), // -A
	.s_axis_a_tvalid(fnmaddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fnmaddvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fnmaddvalid),
	.aclk(clock),
	.m_axis_result_tdata(fnmaddresult),
	.m_axis_result_tvalid(fnmaddresultvalid) );

fp_add floatadd(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(faddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(faddvalid),
	.aclk(clock),
	.m_axis_result_tdata(faddresult),
	.m_axis_result_tvalid(faddresultvalid) );
	
fp_sub floatsub(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fsubresult),
	.m_axis_result_tvalid(fsubresultvalid) );


fp_mul floatmul(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmulvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmulvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmulresult),
	.m_axis_result_tvalid(fmulresultvalid) );

fp_div floatdiv(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fdivvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fdivvalid),
	.aclk(clock),
	.m_axis_result_tdata(fdivresult),
	.m_axis_result_tvalid(fdivresultvalid) );

fp_i2f floati2f(
	.s_axis_a_tdata(rval1), // Integer source
	.s_axis_a_tvalid(fi2fvalid),
	.aclk(clock),
	.m_axis_result_tdata(fi2fresult),
	.m_axis_result_tvalid(fi2fresultvalid) );

fp_ui2f floatui2f(
	.s_axis_a_tdata(rval1), // Integer source
	.s_axis_a_tvalid(fui2fvalid),
	.aclk(clock),
	.m_axis_result_tdata(fui2fresult),
	.m_axis_result_tvalid(fui2fresultvalid) );

fp_f2i floatf2i(
	.s_axis_a_tdata(frval1), // Float source
	.s_axis_a_tvalid(ff2ivalid),
	.aclk(clock),
	.m_axis_result_tdata(ff2iresult),
	.m_axis_result_tvalid(ff2iresultvalid) );

// NOTE: Sharing same logic with f2i here, ignoring sign bit instead
fp_f2i floatf2ui(
	.s_axis_a_tdata({1'b0,frval1[30:0]}), // abs(A) (float register is source)
	.s_axis_a_tvalid(ff2uivalid),
	.aclk(clock),
	.m_axis_result_tdata(ff2uiresult),
	.m_axis_result_tvalid(ff2uiresultvalid) );
	
fp_sqrt floatsqrt(
	.s_axis_a_tdata({1'b0,frval1[30:0]}), // abs(A) (float register is source)
	.s_axis_a_tvalid(fsqrtvalid),
	.aclk(clock),
	.m_axis_result_tdata(fsqrtresult),
	.m_axis_result_tvalid(fsqrtresultvalid) );

fp_eq floateq(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(feqvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(feqvalid),
	.aclk(clock),
	.m_axis_result_tdata(feqresult),
	.m_axis_result_tvalid(feqresultvalid) );

fp_lt floatlt(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fltvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fltvalid),
	.aclk(clock),
	.m_axis_result_tdata(fltresult),
	.m_axis_result_tvalid(fltresultvalid) );

fp_le floatle(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(flevalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(flevalid),
	.aclk(clock),
	.m_axis_result_tdata(fleresult),
	.m_axis_result_tvalid(fleresultvalid) );

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
// MDRU (mul-div-rem unit)
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

					// Trigger interrupts
					timerinterrupt <= CSRReg[`CSR_MIE][7] & timertrigger;
					externalinterrupt <= (CSRReg[`CSR_MIE][11] & irqtrigger);

					// Update CSRs with internal counters
					{CSRReg[`CSR_CYCLEHI], CSRReg[`CSR_CYCLELO]} <= internalcyclecounter;
					{CSRReg[`CSR_TIMEHI], CSRReg[`CSR_TIMELO]} <= internalwallclockcounter2;
					{CSRReg[`CSR_RETIHI], CSRReg[`CSR_RETILO]} <= internalretirecounter;

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
				dcacheicachesync <= 1'b0;
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
							dataout <= (instrOneHot[`O_H_FLOAT_STW]) ? frval2 : rval2;
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
				end else if (instrOneHot[`O_H_FLOAT_OP] || instrOneHot[`O_H_FLOAT_MADD] || instrOneHot[`O_H_FLOAT_MSUB] || instrOneHot[`O_H_FLOAT_NMSUB] || instrOneHot[`O_H_FLOAT_NMADD]) begin
					// Handle FPU operations
					cpumode[CPU_FPU] <= 1'b1;
				end else begin
					// Pre-arrange math inputs
					dividend <= rval1;
					divisor <= rval2;
					multiplicand <= rval1;
					multiplier <= rval2;
					cpumode[CPU_EXEC] <= 1'b1;
				end
			end
			
			cpumode[CPU_FPU]: begin
				if (instrOneHot[`O_H_FLOAT_MADD] || instrOneHot[`O_H_FLOAT_MSUB] || instrOneHot[`O_H_FLOAT_NMSUB] || instrOneHot[`O_H_FLOAT_NMADD])
					cpumode[CPU_FMSTALL] <= 1'b1;
				else if (func7 ==`FSGNJ || func7 ==`FMVXW || func7 ==`FMVWX )
					cpumode[CPU_RETIRE] <= 1'b1;
				else
					cpumode[CPU_FSTALL] <= 1'b1;
				
				case (1'b1)
					instrOneHot[`O_H_FLOAT_OP]: begin
						case (func7)
							`FSGNJ: begin
								frwe <= 1'b1;
								case(func3)
									3'b000: begin // FSGNJ
										frdin <= {frval2[31], frval1[30:0]}; 
									end
									3'b001: begin  // FSGNJN
										frdin <= {~frval2[31], frval1[30:0]};
									end
									3'b010: begin  // FSGNJX
										frdin <= {frval1[31]^frval2[31], frval1[30:0]};
									end
								endcase
							end
							`FMVXW: begin
								rwe <= 1'b1;
								if (func3 == 3'b000) // FMVXW
									rdin <= frval1;
								else // FCLASS
									rdin <= 32'd0; // TODO: classify the float (doesn't seem to be used by any code)
							end
							`FMVWX: begin
								frwe <= 1'b1;
								frdin <= multiplicand; // rval1; multiplicant already equals to a copy of rval1
							end
							`FADD: begin
								faddvalid <= 1'b1;
							end
							`FSUB: begin
								fsubvalid <= 1'b1;
							end	
							`FMUL: begin
								fmulvalid <= 1'b1;
							end	
							`FDIV: begin
								fdivvalid <= 1'b1;
							end
							`FCVTSW: begin	
								fi2fvalid <= (rs2==5'b00000) ? 1'b1:1'b0; // Signed
								fui2fvalid <= (rs2==5'b00001) ? 1'b1:1'b0; // Unsigned
							end
							`FCVTWS: begin
								ff2ivalid <= (rs2==5'b00000) ? 1'b1:1'b0; // Signed
								ff2uivalid <= (rs2==5'b00001) ? 1'b1:1'b0; // Unsigned
							end
							`FSQRT: begin
								fsqrtvalid <= 1'b1;
							end
							`FEQ: begin
								feqvalid <= (func3==3'b010) ? 1'b1:1'b0; // FEQ
								fltvalid <= (func3==3'b001) ? 1'b1:1'b0; // FLT
								flevalid <= (func3==3'b000) ? 1'b1:1'b0; // FLE
							end
							`FMAX: begin
								fltvalid <= 1'b1; // FLT
							end
						endcase
					end

					instrOneHot[`O_H_FLOAT_MADD]: begin
						fmaddvalid <= 1'b1;
					end

					instrOneHot[`O_H_FLOAT_MSUB]: begin
						fmsubvalid <= 1'b1;
					end

					instrOneHot[`O_H_FLOAT_NMSUB]: begin
						fnmsubvalid <= 1'b1; // is actually MADD!
					end

					instrOneHot[`O_H_FLOAT_NMADD]: begin
						fnmaddvalid <= 1'b1; // is actually MSUB!
					end

				endcase
			end

			cpumode[CPU_LOAD]: begin
				busre <= 1'b0;
				if (busbusy) begin
					cpumode[CPU_LOAD] <= 1'b1;
				end else begin
					if (instrOneHot[`O_H_FLOAT_LDW]) begin
						frwe <= 1'b1;
					end else begin
						rwe <= 1'b1;
					end
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
							if (instrOneHot[`O_H_FLOAT_LDW])
								frdin <= busdata[31:0];
							else
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

					instrOneHot[`O_H_FENCE]: begin
						case (func3)
							3'b000: begin
								// FENCE (across harts, pred/succ ordering of IORW ops)
							end
							3'b001: begin
								// FENCE.I (D$->I$)
								dcacheicachesync <= 1'b1;
							end
						endcase
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
						// TODO: Some custom instruction extensions will go in here
					end

					default: begin
						illegalinstruction <= CSRReg[`CSR_MIE][3];
					end
				endcase
			end
			
			cpumode[CPU_FSTALL]: begin
				faddvalid <= 1'b0;
				fsubvalid <= 1'b0;
				fmulvalid <= 1'b0;
				fdivvalid <= 1'b0;
				fi2fvalid <= 1'b0;
				fui2fvalid <= 1'b0;
				ff2ivalid <= 1'b0;
				ff2uivalid <= 1'b0;
				fsqrtvalid <= 1'b0;
				feqvalid <= 1'b0;
				fltvalid <= 1'b0;
				flevalid <= 1'b0;

				if  (fmulresultvalid | fdivresultvalid | fi2fresultvalid | fui2fresultvalid | ff2iresultvalid | ff2uiresultvalid | faddresultvalid | fsubresultvalid | fsqrtresultvalid | feqresultvalid | fltresultvalid | fleresultvalid) begin
					cpumode[CPU_RETIRE] <= 1'b1;
					case (func7)
						`FADD: begin
							frwe <= 1'b1;
							frdin <= faddresult;
						end
						`FSUB: begin
							frwe <= 1'b1;
							frdin <= fsubresult;
						end
						`FMUL: begin
							frwe <= 1'b1;
							frdin <= fmulresult;
						end
						`FDIV: begin
							frwe <= 1'b1;
							frdin <= fdivresult;
						end
						`FCVTSW: begin // NOTE: FCVT.S.WU is unsigned version
							frwe <= 1'b1;
							frdin <= rs2==5'b00000 ? fi2fresult : fui2fresult; // Result goes to float register (signed int to float)
						end
						`FCVTWS: begin // NOTE: FCVT.WU.S is unsigned version
							rwe <= 1'b1;
							rdin <= rs2==5'b00000 ? ff2iresult : ff2uiresult; // Result goes to integer register (float to signed int)
						end
						`FSQRT: begin
							frwe <= 1'b1;
							frdin <= fsqrtresult;
						end
						`FEQ: begin
							rwe <= 1'b1;
							if (func3==3'b010) // FEQ
								rdin <= {31'd0,feqresult[0]};
							else if (func3==3'b001) // FLT
								rdin <= {31'd0,fltresult[0]};
							else //if (func3==3'b000) // FLE
								rdin <= {31'd0,fleresult[0]};
						end
						`FMIN: begin
							frwe <= 1'b1;
							if (func3==3'b000) // FMIN
								frdin <= fltresult[0]==1'b0 ? frval2 : frval1;
							else // FMAX
								frdin <= fltresult[0]==1'b0 ? frval1 : frval2;
						end
					endcase
				end else begin
					cpumode[CPU_FSTALL] <= 1'b1; // Stall further for float op
				end
			end


			cpumode[CPU_FMSTALL]: begin
				fmaddvalid <= 1'b0;
				fmsubvalid <= 1'b0;
				fnmsubvalid <= 1'b0;
				fnmaddvalid <= 1'b0;
				if (fnmsubresultvalid | fnmaddresultvalid | fmsubresultvalid | fmaddresultvalid) begin
					frwe <= 1'b1;
					cpumode[CPU_RETIRE] <= 1'b1;
					case (1'b1)
						instrOneHot[`O_H_FLOAT_NMSUB]: begin
							frdin <= fnmsubresult;
						end
						instrOneHot[`O_H_FLOAT_NMADD]: begin
							frdin <= fnmaddresult;
						end
						instrOneHot[`O_H_FLOAT_MADD]: begin
							frdin <= fmaddresult;
						end
						instrOneHot[`O_H_FLOAT_MSUB]: begin
							frdin <= fmsubresult;
						end
					endcase
				end else begin
					cpumode[CPU_FMSTALL] <= 1'b1; // Stall further for fused float
				end
			end

			cpumode[CPU_MSTALL]: begin
				if (imathbusy) begin
					// Keep stalling while MDRU is busy
					cpumode[CPU_MSTALL] <= 1'b1;
				end else begin
					case (aluop)
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
				CSRReg[`CSR_MSCRATCH] <= 32'd0; //instruction; // Store the offending instruction for IEX (NOTE: CPU can read it form address in CSR_MTVAL instead)
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
				frwe <= 1'b0;

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

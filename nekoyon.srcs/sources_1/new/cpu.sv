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
logic illegalinstruction;

localparam CPU_RESET	 = 0;
localparam CPU_RETIRE	 = 1;
localparam CPU_FETCH	 = 2;
localparam CPU_DECODE	 = 3;
localparam CPU_EXEC		 = 4;
localparam CPU_LOAD		 = 5;
localparam CPU_UPDATECSR = 6;

logic [6:0] cpumode;

logic [31:0] immreach;
logic [31:0] immpc;
logic [31:0] pc4;
logic [31:0] branchpc;

wire [4:0] opcode;
wire [3:0] aluop;
wire [3:0] bluop;
wire [2:0] func3;
wire [6:0] func7;
wire [11:0] func12;
wire [4:0] rs1;
wire [4:0] rs2;
wire [4:0] rs3;
wire [4:0] rd;
wire [11:0] csrindex;
wire [31:0] immed;
wire selectimmedasrval2;

wire [31:0] rval1;
wire [31:0] rval2;
logic rwe = 1'b0;
logic [31:0] rdin;

wire [31:0] aluout;
wire branchout;

logic [4:0] CSRIndextoLinearIndex;
logic [31:0] CSRReg [0:24];

logic [63:0] internalcyclecounter = 64'd0;
logic [63:0] internalwallclockcounter = 64'd0;
logic [63:0] internalwallclockcounter1 = 64'd0;
logic [63:0] internalwallclockcounter2 = 64'd0;
logic [63:0] internaltimecmp = 64'd0;
logic timertrigger = 1'b0;
logic [63:0] internalretirecounter = 64'd0;
logic timerinterrupt = 1'b0;
logic externalinterrupt = 1'b0;

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
	.opcode(opcode),
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
	branchpc = PC + (branchout ? immed : 32'd4);
end

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

always @(posedge clock) begin
	case (csrindex)
		12'h001: CSRIndextoLinearIndex <= `CSR_FFLAGS;
		12'h002: CSRIndextoLinearIndex <= `CSR_FRM;
		12'h003: CSRIndextoLinearIndex <= `CSR_FCSR;
		12'h300: CSRIndextoLinearIndex <= `CSR_MSTATUS;
		12'h301: CSRIndextoLinearIndex <= `CSR_MISA;
		12'h304: CSRIndextoLinearIndex <= `CSR_MIE;
		12'h305: CSRIndextoLinearIndex <= `CSR_MTVEC;
		12'h340: CSRIndextoLinearIndex <= `CSR_MSCRATCH;
		12'h341: CSRIndextoLinearIndex <= `CSR_MEPC;
		12'h342: CSRIndextoLinearIndex <= `CSR_MCAUSE;
		12'h343: CSRIndextoLinearIndex <= `CSR_MTVAL;
		12'h344: CSRIndextoLinearIndex <= `CSR_MIP;
		12'h780: CSRIndextoLinearIndex <= `CSR_DCSR;
		12'h781: CSRIndextoLinearIndex <= `CSR_DPC;
		12'h800: CSRIndextoLinearIndex <= `CSR_TIMECMPLO;
		12'h801: CSRIndextoLinearIndex <= `CSR_TIMECMPHI;
		12'hB00: CSRIndextoLinearIndex <= `CSR_CYCLELO;
		12'hB80: CSRIndextoLinearIndex <= `CSR_CYCLEHI;
		12'hC01: CSRIndextoLinearIndex <= `CSR_TIMELO;
		12'hC02: CSRIndextoLinearIndex <= `CSR_RETILO;
		12'hC81: CSRIndextoLinearIndex <= `CSR_TIMEHI;
		12'hC82: CSRIndextoLinearIndex <= `CSR_RETIHI;
		12'hF14: CSRIndextoLinearIndex <= `CSR_HARTID;
		default: CSRIndextoLinearIndex <= `CSR_UNUSED;
	endcase
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
	internalretirecounter <= internalretirecounter + {63'd0, cpumode[CPU_RETIRE]};
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
					cpumode[CPU_DECODE] <= 1'b1;
				end
			end

			cpumode[CPU_DECODE]: begin
				nextPC <= pc4;
				ifetch <= 1'b0;

				// Update CSRs with internal counters
				{CSRReg[`CSR_CYCLEHI], CSRReg[`CSR_CYCLELO]} <= internalcyclecounter;
				{CSRReg[`CSR_TIMEHI], CSRReg[`CSR_TIMELO]} <= internalwallclockcounter2;
				{CSRReg[`CSR_RETIHI], CSRReg[`CSR_RETILO]} <= internalretirecounter;

				// Trigger interrupts
				timerinterrupt <= CSRReg[`CSR_MIE][7] & timertrigger;
				externalinterrupt <= (CSRReg[`CSR_MIE][11] & irqtrigger);

				// Take load or op branch, otherwise process store in-place
				if (opcode == `OPCODE_LOAD || opcode == `OPCODE_FLOAT_LDW) begin
					busaddress <= immreach;
					busre <= 1'b1;
					cpumode[CPU_LOAD] <= 1'b1;
				end else if (opcode == `OPCODE_STORE || opcode == `OPCODE_FLOAT_STW) begin
					busaddress <= immreach;
					case (func3)
						3'b000: begin // BYTE
							dataout <= {rval2[7:0], rval2[7:0], rval2[7:0], rval2[7:0]};
							unique case (immreach[1:0])
								2'b11: begin buswe <= 4'h8; end
								2'b10: begin buswe <= 4'h4; end
								2'b01: begin buswe <= 4'h2; end
								2'b00: begin buswe <= 4'h1; end
							endcase
						end
						3'b001: begin // WORD
							dataout <= {rval2[15:0], rval2[15:0]};
							unique case (immreach[1])
								1'b1: begin buswe <= 4'hC; end
								1'b0: begin buswe <= 4'h3; end
							endcase
						end
						default: begin // DWORD
							dataout <= /*(opcode == `OPCODE_FLOAT_STW) ? frval2 :*/ rval2;
							buswe <= 4'hF;
						end
					endcase
					cpumode[CPU_RETIRE] <= 1'b1;
				end else begin
					cpumode[CPU_EXEC] <= 1'b1;
				end
			end

			cpumode[CPU_LOAD]: begin
				busre <= 1'b0;
				if (busbusy) begin
					cpumode[CPU_LOAD] <= 1'b1;
				end else begin
					/*if (opcode == `OPCODE_FLOAT_LDW) begin
						frwe <= 1'b1;
					end else begin*/
						rwe <= 1'b1;
					/*end*/
					unique case (func3)
						3'b000: begin // BYTE with sign extension
							unique case (busaddress[1:0])
								2'b11: begin rdin <= {{24{busdata[31]}}, busdata[31:24]}; end
								2'b10: begin rdin <= {{24{busdata[23]}}, busdata[23:16]}; end
								2'b01: begin rdin <= {{24{busdata[15]}}, busdata[15:8]}; end
								2'b00: begin rdin <= {{24{busdata[7]}},  busdata[7:0]}; end
							endcase
						end
						3'b001: begin // WORD with sign extension
							unique case (busaddress[1])
								1'b1: begin rdin <= {{16{busdata[31]}}, busdata[31:16]}; end
								1'b0: begin rdin <= {{16{busdata[15]}}, busdata[15:0]}; end
							endcase
						end
						3'b010: begin // DWORD
							/*if (opcode == `OPCODE_FLOAT_LDW)
								fregdata <= busdata[31:0];
							else*/
								rdin <= busdata[31:0];
						end
						3'b100: begin // BYTE with zero extension
							unique case (busaddress[1:0])
								2'b11: begin rdin <= {24'd0, busdata[31:24]}; end
								2'b10: begin rdin <= {24'd0, busdata[23:16]}; end
								2'b01: begin rdin <= {24'd0, busdata[15:8]}; end
								2'b00: begin rdin <= {24'd0, busdata[7:0]}; end
							endcase
						end
						3'b101: begin // WORD with zero extension
							unique case (busaddress[1])
								1'b1: begin rdin <= {16'd0, busdata[31:16]}; end
								1'b0: begin rdin <= {16'd0, busdata[15:0]}; end
							endcase
						end
					endcase
					cpumode[CPU_RETIRE] <= 1'b1;
				end
			end

			cpumode[CPU_EXEC]: begin
				ebreak <= 1'b0;
				illegalinstruction <= 1'b0;

				case (opcode)
					`OPCODE_AUPC: begin
						rwe <= 1'b1;
						rdin <= immpc;
					end
					`OPCODE_LUI: begin
						rwe <= 1'b1;
						rdin <= immed;
					end
					`OPCODE_JAL: begin
						rwe <= 1'b1;
						rdin <= pc4;
						nextPC <= immpc;
					end
					`OPCODE_OP, `OPCODE_OP_IMM: begin
						rwe <= 1'b1;
						rdin <= aluout;
					end
					`OPCODE_FLOAT_OP: begin
						// TBD
					end
					`OPCODE_FLOAT_MADD, `OPCODE_FLOAT_MSUB, `OPCODE_FLOAT_NMSUB, `OPCODE_FLOAT_NMADD: begin
						// TBD
					end
					`OPCODE_FENCE: begin
						// TBD
					end
					`OPCODE_SYSTEM: begin
						unique case (func3)
							// ECALL/EBREAK
							3'b000: begin
								unique case (func12)
									12'b000000000000: begin // ECALL
										// TBD:
										// li a7, SBI_SHUTDOWN // also a0/a1/a2, retval in a0
  										// ecall
  									end
									12'b000000000001: begin // EBREAK
										ebreak <= CSRReg[`CSR_MIE][3];
									end
									// privileged instructions
									12'b001100000010: begin // MRET
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd3) CSRReg[`CSR_MIP][3] <= 1'b0;	// Disable machine software interrupt pending
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd7) CSRReg[`CSR_MIP][7] <= 1'b0;	// Disable machine timer interrupt pending
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd11) CSRReg[`CSR_MIP][11] <= 1'b0;	// Disable machine external interrupt pending
										CSRReg[`CSR_MSTATUS][3] <= CSRReg[`CSR_MSTATUS][7];						// MIE=MPIE - set to previous machine interrupt enable state
										CSRReg[`CSR_MSTATUS][7] <= 1'b0;										// Clear MPIE
										nextPC <= CSRReg[`CSR_MEPC];
									end
								endcase
								cpumode[CPU_RETIRE] <= 1'b1;
							end
							// CSRRW/CSRRS/CSSRRC/CSRRWI/CSRRSI/CSRRCI
							3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: begin 
								rwe <= 1'b1;
								rdin <= CSRReg[CSRIndextoLinearIndex];
								cpumode[CPU_UPDATECSR] <= 1'b1;
							end
							// Unknown
							default: begin
								cpumode[CPU_RETIRE] <= 1'b1;
							end
						endcase
					end
					`OPCODE_JALR: begin
						rwe <= 1'b1;
						rdin <= pc4;
						nextPC <= immreach;
					end
					`OPCODE_BRANCH: begin
						nextPC <= branchpc;
					end
					default: begin
						illegalinstruction <= CSRReg[`CSR_MIE][3];
					end
				endcase

				cpumode[CPU_RETIRE] <= 1'b1;
			end

			cpumode[CPU_UPDATECSR]: begin
				// Stop writes to integer register file
				rwe <= 1'b0;
				
				// Write to r/w CSR
				case(func3)
					3'b001: begin // CSRRW
						CSRReg[CSRIndextoLinearIndex] <= rval1;
					end
					3'b101: begin // CSRRWI
						CSRReg[CSRIndextoLinearIndex] <= immed;
					end
					3'b010: begin // CSRRS
						CSRReg[CSRIndextoLinearIndex] <= rdin | rval1;
					end
					3'b110: begin // CSRRSI
						CSRReg[CSRIndextoLinearIndex] <= rdin | immed;
					end
					3'b011: begin // CSSRRC
						CSRReg[CSRIndextoLinearIndex] <= rdin & (~rval1);
					end
					3'b111: begin // CSRRCI
						CSRReg[CSRIndextoLinearIndex] <= rdin & (~immed);
					end
					default: begin // Unknown
						CSRReg[CSRIndextoLinearIndex] <= rdin;
					end
				endcase
				cpumode[CPU_RETIRE] <= 1'b1;
			end

			cpumode[CPU_RETIRE]: begin
				// Stop memory reads/writes
				buswe <= 1'b0;
				busre <= 1'b0;

				// End register writes
				rwe <= 1'b0;

				if (busbusy) begin
					cpumode[CPU_RETIRE] <= 1'b1;
				end else begin
					PC <= nextPC;
					busaddress <= nextPC;
					ifetch <= 1'b1;
					busre <= 1'b1;

					// Copy CSR states to internal registers
					internaltimecmp <= {CSRReg[`CSR_TIMECMPHI], CSRReg[`CSR_TIMECMPLO]};

					if (CSRReg[`CSR_MSTATUS][3]) begin
						// Common action in case of 'any' interrupt
						if (illegalinstruction | ebreak | timerinterrupt | externalinterrupt) begin
							CSRReg[`CSR_MSTATUS][7] <= CSRReg[`CSR_MSTATUS][3]; // Remember interrupt enable status in pending state (MPIE = MIE)
							CSRReg[`CSR_MSTATUS][3] <= 1'b0; // Clear interrupts during handler
							CSRReg[`CSR_MTVAL] <= illegalinstruction ? PC : 32'd0; // Store interrupt/exception specific data (default=0)
							CSRReg[`CSR_MSCRATCH] <= illegalinstruction ? instruction : 32'd0; // Store the offending instruction for IEX
							CSRReg[`CSR_MEPC] <= ebreak ? PC : nextPC; // Remember where to return (special case; ebreak returns to same PC as breakpoint)
							// Jump to handler
							// Set up non-vectored branch (always assume CSRReg[`CSR_MTVEC][1:0]==2'b00)
							PC <= {CSRReg[`CSR_MTVEC][31:2],2'b00};
							busaddress <= {CSRReg[`CSR_MTVEC][31:2],2'b00};
						end

						// Set interrupt pending bits
						// NOTE: illegal instruction and ebreak both create the same machine software interrupt
						{CSRReg[`CSR_MIP][3], CSRReg[`CSR_MIP][7], CSRReg[`CSR_MIP][11]} <= {illegalinstruction | ebreak, timerinterrupt, externalinterrupt};

						unique case (1'b1)
							illegalinstruction, ebreak: begin
								CSRReg[`CSR_MCAUSE][15:0] <= 16'd3; // Illegal instruction or breakpoint interrupt
								CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 14'd0, illegalinstruction ? 1'b1:1'b0}; // Cause: 0: ebreak 1: illegal instruction
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
					end

					cpumode[CPU_FETCH] <= 1'b1;
				end
			end

		endcase
	end

end

endmodule

// =============================================================================
// isa_probe_cpu.sv -- sweep every RV32 encoding through the REAL decoder
// =============================================================================
// The instruction table in docs/ISA_CPU.md is not transcribed from the source
// by a person; it is produced by driving asicirific's own control_unit with
// every opcode / funct3 / funct7 combination that matters and recording what
// it decides. Two consequences worth the trouble:
//
//   1. the table cannot be wrong about the hardware, only incomplete about
//      the sweep, and the sweep is printed;
//   2. it says which encodings this CPU actually accepts -- `legal` comes
//      from the decoder, so instructions the core does NOT implement show up
//      as illegal instead of being quietly listed as supported.
//
// Output is CSV on stdout: tools/isa/gen_cpu_isa.py turns it into the table.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module isa_probe_cpu;
  import asicirific_pkg::*;

  logic [31:0] inst;
  ctrl_t       ctrl;

  control_unit #(.ENABLE_M(1'b1)) dut (.inst(inst), .ctrl(ctrl));

  // A canonical encoding for one (opcode, funct3, funct7) triple with
  // rd = x1, rs1 = x2, rs2 = x3, so the register fields never alias the
  // fields under test.
  function automatic logic [31:0] enc(input logic [6:0] opc,
                                      input logic [2:0] f3,
                                      input logic [6:0] f7);
    enc = {f7, 5'd3, 5'd2, f3, 5'd1, opc};
  endfunction

  task automatic probe(input string mnemonic, input logic [6:0] opc,
                       input logic [2:0] f3, input logic [6:0] f7,
                       input bit f3_used, input bit f7_used);
    inst = enc(opc, f3, f7);
    #1;
    // funct3/funct7 always printed; the *_used flags say whether the decoder
    // looks at them for this opcode. ($sformatf into %s misbehaved here.)
    $display("%s,%07b,%03b,%0d,%07b,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
             mnemonic, opc, f3, f3_used, f7, f7_used,
             ctrl.legal, ctrl.rf_we, ctrl.wb_sel,
             ctrl.alu_op, ctrl.alu_a_pc, ctrl.alu_b_imm, ctrl.imm_sel,
             ctrl.is_branch | ctrl.is_jal | ctrl.is_jalr,
             ctrl.mem_read, ctrl.mem_write, ctrl.is_csr,
             ctrl.is_mul | ctrl.is_div);
  endtask

  initial begin
    $display("mnemonic,opcode,funct3,f3_used,funct7,f7_used,legal,rf_we,wb_sel,alu_op,alu_a_pc,alu_b_imm,imm_sel,control_flow,mem_read,mem_write,is_csr,is_muldiv");

    // ---- U and J types: no funct fields ---------------------------------
    probe("LUI",   7'b0110111, 3'b000, 7'b0000000, 0, 0);
    probe("AUIPC", 7'b0010111, 3'b000, 7'b0000000, 0, 0);
    probe("JAL",   7'b1101111, 3'b000, 7'b0000000, 0, 0);
    probe("JALR",  7'b1100111, 3'b000, 7'b0000000, 1, 0);

    // ---- branches --------------------------------------------------------
    probe("BEQ",  7'b1100011, 3'b000, 7'b0000000, 1, 0);
    probe("BNE",  7'b1100011, 3'b001, 7'b0000000, 1, 0);
    probe("B?010", 7'b1100011, 3'b010, 7'b0000000, 1, 0);   // unallocated
    probe("B?011", 7'b1100011, 3'b011, 7'b0000000, 1, 0);   // unallocated
    probe("BLT",  7'b1100011, 3'b100, 7'b0000000, 1, 0);
    probe("BGE",  7'b1100011, 3'b101, 7'b0000000, 1, 0);
    probe("BLTU", 7'b1100011, 3'b110, 7'b0000000, 1, 0);
    probe("BGEU", 7'b1100011, 3'b111, 7'b0000000, 1, 0);

    // ---- loads and stores -------------------------------------------------
    probe("LB",  7'b0000011, 3'b000, 7'b0000000, 1, 0);
    probe("LH",  7'b0000011, 3'b001, 7'b0000000, 1, 0);
    probe("LW",  7'b0000011, 3'b010, 7'b0000000, 1, 0);
    probe("LBU", 7'b0000011, 3'b100, 7'b0000000, 1, 0);
    probe("LHU", 7'b0000011, 3'b101, 7'b0000000, 1, 0);
    probe("SB",  7'b0100011, 3'b000, 7'b0000000, 1, 0);
    probe("SH",  7'b0100011, 3'b001, 7'b0000000, 1, 0);
    probe("SW",  7'b0100011, 3'b010, 7'b0000000, 1, 0);

    // ---- register-immediate ----------------------------------------------
    probe("ADDI",  7'b0010011, 3'b000, 7'b0000000, 1, 0);
    probe("SLTI",  7'b0010011, 3'b010, 7'b0000000, 1, 0);
    probe("SLTIU", 7'b0010011, 3'b011, 7'b0000000, 1, 0);
    probe("XORI",  7'b0010011, 3'b100, 7'b0000000, 1, 0);
    probe("ORI",   7'b0010011, 3'b110, 7'b0000000, 1, 0);
    probe("ANDI",  7'b0010011, 3'b111, 7'b0000000, 1, 0);
    probe("SLLI",  7'b0010011, 3'b001, 7'b0000000, 1, 1);
    probe("SRLI",  7'b0010011, 3'b101, 7'b0000000, 1, 1);
    probe("SRAI",  7'b0010011, 3'b101, 7'b0100000, 1, 1);

    // ---- register-register ------------------------------------------------
    probe("ADD",  7'b0110011, 3'b000, 7'b0000000, 1, 1);
    probe("SUB",  7'b0110011, 3'b000, 7'b0100000, 1, 1);
    probe("SLL",  7'b0110011, 3'b001, 7'b0000000, 1, 1);
    probe("SLT",  7'b0110011, 3'b010, 7'b0000000, 1, 1);
    probe("SLTU", 7'b0110011, 3'b011, 7'b0000000, 1, 1);
    probe("XOR",  7'b0110011, 3'b100, 7'b0000000, 1, 1);
    probe("SRL",  7'b0110011, 3'b101, 7'b0000000, 1, 1);
    probe("SRA",  7'b0110011, 3'b101, 7'b0100000, 1, 1);
    probe("OR",   7'b0110011, 3'b110, 7'b0000000, 1, 1);
    probe("AND",  7'b0110011, 3'b111, 7'b0000000, 1, 1);

    // ---- RV32M --------------------------------------------------------------
    probe("MUL",    7'b0110011, 3'b000, 7'b0000001, 1, 1);
    probe("MULH",   7'b0110011, 3'b001, 7'b0000001, 1, 1);
    probe("MULHSU", 7'b0110011, 3'b010, 7'b0000001, 1, 1);
    probe("MULHU",  7'b0110011, 3'b011, 7'b0000001, 1, 1);
    probe("DIV",    7'b0110011, 3'b100, 7'b0000001, 1, 1);
    probe("DIVU",   7'b0110011, 3'b101, 7'b0000001, 1, 1);
    probe("REM",    7'b0110011, 3'b110, 7'b0000001, 1, 1);
    probe("REMU",   7'b0110011, 3'b111, 7'b0000001, 1, 1);

    // ---- system and fence ---------------------------------------------------
    probe("ECALL/EBREAK", 7'b1110011, 3'b000, 7'b0000000, 1, 0);
    probe("CSRRW",  7'b1110011, 3'b001, 7'b0000000, 1, 0);
    probe("CSRRS",  7'b1110011, 3'b010, 7'b0000000, 1, 0);
    probe("CSRRC",  7'b1110011, 3'b011, 7'b0000000, 1, 0);
    probe("CSRRWI", 7'b1110011, 3'b101, 7'b0000000, 1, 0);
    probe("CSRRSI", 7'b1110011, 3'b110, 7'b0000000, 1, 0);
    probe("CSRRCI", 7'b1110011, 3'b111, 7'b0000000, 1, 0);
    probe("FENCE",  7'b0001111, 3'b000, 7'b0000000, 1, 0);

    // ---- encodings that must be rejected ------------------------------------
    probe("(bad opcode)",  7'b1111111, 3'b000, 7'b0000000, 0, 0);
    probe("(bad load f3)", 7'b0000011, 3'b111, 7'b0000000, 1, 0);
    probe("(bad store f3)",7'b0100011, 3'b111, 7'b0000000, 1, 0);
    probe("(bad op f7)",   7'b0110011, 3'b000, 7'b0100001, 1, 1);
    $finish;
  end
endmodule

`default_nettype wire

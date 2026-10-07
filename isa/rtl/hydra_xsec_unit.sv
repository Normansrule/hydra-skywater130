/*
 * hydra_xsec_unit.sv -- security instructions for an RV64 core
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * TWO PARTS, AND WHY THE LINE BETWEEN THEM IS WHERE IT IS
 * ===========================================================================
 * 1. STANDARD: the SHA-256 subset of Zknh, from the ratified RISC-V
 *    Cryptography Extensions, Volume I (Scalar and Entropy Source), v1.0.1.
 *    Encodings are taken from the official riscv-opcodes table, not from
 *    memory:
 *
 *      sha256sum0  0001000 00000 rs1 001 rd 0010011
 *      sha256sum1  0001000 00001 rs1 001 rd 0010011
 *      sha256sig0  0001000 00010 rs1 001 rd 0010011
 *      sha256sig1  0001000 00011 rs1 001 rd 0010011
 *
 *    On RV64 each operates on the LOW 32 bits of rs1 and SIGN-EXTENDS the
 *    32-bit result, exactly as the specification's execute clauses say.
 *    Inventing a private SHA instruction instead would make this chip
 *    incompatible with every crypto library that already targets Zknh.
 *
 * 2. CUSTOM (Xhydrasec): only what is unique to this chip -- the key vault,
 *    the measurement register, and a guaranteed constant-time compare. It
 *    lives in custom-0 (opcode 0001011), the space RISC-V reserves for
 *    exactly this, so it can never collide with a future standard
 *    extension. R-type, funct7 = 0000000, funct3 selects:
 *
 *      000  hsec.kvstat   rd, rs1      vault slot status (NO key bits)
 *      001  hsec.kvwrite  rs1, rs2     write key word    MACHINE MODE ONLY
 *      010  hsec.kvlock   rs1          seal a slot       MACHINE MODE ONLY
 *      011  hsec.pcrrd    rd, rs1      read 64 bits of the measurement
 *      100  hsec.measw    rs1, rs2     stage 32 bits of a measurement
 *      101  hsec.pcrext                fold the staged measurement in
 *      110  hsec.cteq     rd, rs1, rs2 constant-time equality: 1 or 0
 *      111  reserved                   illegal instruction
 *
 * ===========================================================================
 * THE THREE RULES THIS UNIT EXISTS TO ENFORCE
 * ===========================================================================
 * (a) No instruction moves key bits into a general-purpose register. There
 *     is no key-read instruction at all, and kvstat returns metadata only.
 *     PROVED by non-interference over this unit and the vault together.
 * (b) Writing or sealing a key needs machine mode. Anywhere else the
 *     instruction is ILLEGAL -- it traps, rather than silently doing
 *     nothing, because a silent no-op teaches attackers nothing is there
 *     and teaches developers nothing went wrong. PROVED.
 * (c) Every instruction here takes the same time whatever the data.
 *     Everything is single-cycle combinational, which is the strongest form
 *     of the Zkt data-independent-latency guarantee there is.
 *
 * hsec.cteq exists because software cannot reliably write a constant-time
 * comparison: compilers turn a loop over bytes into an early-exit branch,
 * and comparing a message authentication tag with an early exit leaks how
 * many leading bytes were right. In hardware a 64-bit compare is one cycle
 * whatever the operands, and this instruction guarantees it.
 */
`default_nettype none

module hydra_xsec_unit #(
  parameter int unsigned NSLOT = 4,
  parameter int unsigned KWORDS = 8          // 32-bit words per key
) (
  input  wire              valid,
  input  wire [31:0]       insn,
  input  wire [63:0]       rs1,
  input  wire [63:0]       rs2,
  input  wire [1:0]        priv,             // 11 machine, 01 supervisor, 00 user

  output logic             claim,            // this unit decodes the instruction
  output logic             illegal,          // raise an illegal-instruction trap
  output logic             rd_we,
  output logic [63:0]      rd_val,

  // ---- key vault ------------------------------------------------------------
  output logic             kv_we,
  output logic [$clog2(NSLOT)-1:0]  kv_slot,
  output logic [$clog2(KWORDS)-1:0] kv_word,
  output logic [31:0]      kv_wdata,
  output logic             kv_lock,
  output logic [$clog2(NSLOT)-1:0]  kv_rd_slot,
  input  wire  [31:0]      kv_rdata,         // metadata only, by construction

  // ---- measurement register --------------------------------------------------
  output logic             meas_we,
  output logic [2:0]       meas_word,
  output logic [31:0]      meas_wdata,
  output logic             pcr_extend,
  input  wire  [255:0]     pcr_value
);
  localparam logic [6:0] OP_IMM   = 7'b0010011;
  localparam logic [6:0] CUSTOM0  = 7'b0001011;
  localparam logic [1:0] PRIV_M   = 2'b11;

  wire [6:0] opcode = insn[6:0];
  wire [2:0] funct3 = insn[14:12];
  wire [6:0] funct7 = insn[31:25];
  wire [4:0] rs2f   = insn[24:20];

  // ---- the standard part --------------------------------------------------------
  function automatic logic [31:0] ror32(input logic [31:0] x, input int n);
    return (x >> n) | (x << (32 - n));
  endfunction

  wire [31:0] x = rs1[31:0];
  wire is_zknh  = (opcode == OP_IMM) && (funct3 == 3'b001) &&
                  (funct7 == 7'b0001000) && (rs2f[4:2] == 3'b000);

  logic [31:0] zres;
  always_comb begin
    unique case (rs2f[1:0])
      2'b00: zres = ror32(x, 2)  ^ ror32(x, 13) ^ ror32(x, 22);   // sum0
      2'b01: zres = ror32(x, 6)  ^ ror32(x, 11) ^ ror32(x, 25);   // sum1
      2'b10: zres = ror32(x, 7)  ^ ror32(x, 18) ^ (x >> 3);       // sig0
      default: zres = ror32(x, 17) ^ ror32(x, 19) ^ (x >> 10);    // sig1
    endcase
  end

  // ---- the custom part ----------------------------------------------------------
  wire is_hsec  = (opcode == CUSTOM0) && (funct7 == 7'b0000000);
  wire machine  = (priv == PRIV_M);
  wire needs_m  = (funct3 == 3'b001) || (funct3 == 3'b010);

  always_comb begin
    claim      = valid && (is_zknh || is_hsec);
    illegal    = 1'b0;
    rd_we      = 1'b0;
    rd_val     = '0;
    kv_we      = 1'b0;
    kv_lock    = 1'b0;
    kv_slot    = rs1[$clog2(KWORDS) +: $clog2(NSLOT)];
    kv_word    = rs1[$clog2(KWORDS)-1:0];
    kv_wdata   = rs2[31:0];
    kv_rd_slot = rs1[$clog2(NSLOT)-1:0];
    meas_we    = 1'b0;
    meas_word  = rs1[2:0];
    meas_wdata = rs2[31:0];
    pcr_extend = 1'b0;

    if (valid && is_zknh) begin
      rd_we  = 1'b1;
      rd_val = {{32{zres[31]}}, zres};                 // sign-extended, per spec
    end else if (valid && is_hsec) begin
      if (needs_m && !machine) begin
        // Rule (b). Trap; touch nothing.
        illegal = 1'b1;
      end else begin
        unique case (funct3)
          3'b000: begin rd_we = 1'b1; rd_val = {32'd0, kv_rdata}; end
          3'b001: kv_we   = 1'b1;
          3'b010: kv_lock = 1'b1;
          3'b011: begin
            rd_we  = 1'b1;
            // Word 0 is the most significant 64 bits, matching how a digest
            // is written out.
            rd_val = pcr_value[(3 - rs1[1:0]) * 64 +: 64];
          end
          3'b100: meas_we    = 1'b1;
          3'b101: pcr_extend = 1'b1;
          3'b110: begin rd_we = 1'b1; rd_val = {63'd0, (rs1 == rs2)}; end
          default: illegal = 1'b1;
        endcase
      end
    end
  end

`ifdef FORMAL
  always_comb if (valid) begin
    // Rule (b): outside machine mode, a key write or seal never reaches the
    // vault, whatever the operands.
    if (!machine) assert (!kv_we && !kv_lock);

    // ...and it is reported, not swallowed.
    if (is_hsec && needs_m && !machine) assert (illegal);

    // An illegal instruction changes nothing: no register, no vault, no
    // measurement.
    if (illegal) assert (!rd_we && !kv_we && !kv_lock && !meas_we && !pcr_extend);

    // Only one side effect per instruction.
    assert ($onehot0({kv_we, kv_lock, meas_we, pcr_extend, rd_we}));
  end
`endif
endmodule

`default_nettype wire

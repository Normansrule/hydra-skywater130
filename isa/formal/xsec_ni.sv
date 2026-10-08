// =============================================================================
// xsec_ni.sv -- no instruction can move key bits into a register
// =============================================================================
// Two copies of the security unit, each wired to its own key vault. Every
// input is IDENTICAL -- the instruction stream, the operands, the privilege
// -- except the key material written into the two vaults, which the solver
// chooses freely and independently. The proof shows every instruction's
// result, write-enable and trap are identical in both copies.
//
// If any instruction sequence could get a key bit into rd -- through kvstat,
// through a mis-decoded opcode, through the reserved encoding, through
// anything -- the two copies would diverge and the proof would show how.
//
// UNBOUNDED (k-induction) since 2026-10-07. The unit itself has no state;
// all state is in the two vaults, and induction needs the fact that their
// bookkeeping (written words, filled and sealed slots) is identical. The
// vault exposes that bookkeeping as proof-only ports, and it is asserted
// here, so the solver proves it rather than assuming it. Run at two sizes:
// two 64-bit slots (task ni) and the shipped four 256-bit slots (ni_full).
// =============================================================================
`default_nettype none
module xsec_ni #(
  parameter int unsigned NSLOT  = 2,
  parameter int unsigned KWORDS = 2
) (
  input wire        clk,
  input wire        rst_n,
  input wire        valid,
  input wire [31:0] insn,
  input wire [63:0] rs1,
  input wire [63:0] rs2,
  input wire [1:0]  priv,
  input wire [31:0] key_a,       // the ONLY difference between the copies
  input wire [31:0] key_b
);
  localparam int unsigned KW = 32 * KWORDS;
  localparam int unsigned SB = $clog2(NSLOT);
  localparam int unsigned WB = $clog2(KWORDS);

  wire          ill_a, ill_b, we_a, we_b;
  wire [63:0]   rd_a, rd_b;
  wire          kwe_a, kwe_b, klk_a, klk_b;
  wire [SB-1:0] ks_a, ks_b, krs_a, krs_b;
  wire [WB-1:0] kw_a, kw_b;
  wire [31:0]   kst_a, kst_b;
  wire [NSLOT-1:0]        lk_a, lk_b, fl_a, fl_b;
  wire [NSLOT*KWORDS-1:0] sn_a, sn_b;

  hydra_xsec_unit #(.NSLOT(NSLOT), .KWORDS(KWORDS)) u_a (
    .valid(valid), .insn(insn), .rs1(rs1), .rs2(rs2), .priv(priv),
    .claim(), .illegal(ill_a), .rd_we(we_a), .rd_val(rd_a),
    .kv_we(kwe_a), .kv_slot(ks_a), .kv_word(kw_a), .kv_wdata(), .kv_lock(klk_a),
    .kv_rd_slot(krs_a), .kv_rdata(kst_a),
    .meas_we(), .meas_word(), .meas_wdata(), .pcr_extend(), .pcr_value(256'd0));

  hydra_xsec_unit #(.NSLOT(NSLOT), .KWORDS(KWORDS)) u_b (
    .valid(valid), .insn(insn), .rs1(rs1), .rs2(rs2), .priv(priv),
    .claim(), .illegal(ill_b), .rd_we(we_b), .rd_val(rd_b),
    .kv_we(kwe_b), .kv_slot(ks_b), .kv_word(kw_b), .kv_wdata(), .kv_lock(klk_b),
    .kv_rd_slot(krs_b), .kv_rdata(kst_b),
    .meas_we(), .meas_word(), .meas_wdata(), .pcr_extend(), .pcr_value(256'd0));

  hydra_key_vault #(.NSLOT(NSLOT), .KW(KW), .WW(32)) v_a (
    .clk(clk), .rst_n(rst_n), .host_we(kwe_a), .host_slot(ks_a), .host_word(kw_a),
    .host_wdata(key_a), .host_lock(klk_a), .host_wipe(1'b0),
    .host_rd_slot(krs_a), .host_rdata(kst_a), .err_locked(),
    .eng_req(1'b0), .eng_slot('0), .eng_key(), .eng_valid(),
    .f_locked(lk_a), .f_filled(fl_a), .f_seen(sn_a));

  hydra_key_vault #(.NSLOT(NSLOT), .KW(KW), .WW(32)) v_b (
    .clk(clk), .rst_n(rst_n), .host_we(kwe_b), .host_slot(ks_b), .host_word(kw_b),
    .host_wdata(key_b), .host_lock(klk_b), .host_wipe(1'b0),
    .host_rd_slot(krs_b), .host_rdata(kst_b), .err_locked(),
    .eng_req(1'b0), .eng_slot('0), .eng_key(), .eng_valid(),
    .f_locked(lk_b), .f_filled(fl_b), .f_seen(sn_b));

`ifdef FORMAL
  logic started = 1'b0;
  always_ff @(posedge clk) started <= 1'b1;
  always_ff @(posedge clk) if (!started) assume (!rst_n);

  always_ff @(posedge clk) if (started) begin
    assert (rd_a  == rd_b);
    assert (we_a  == we_b);
    assert (ill_a == ill_b);
    // induction invariant: the vaults' bookkeeping is identical (proved)
    assert (lk_a == lk_b);
    assert (fl_a == fl_b);
    assert (sn_a == sn_b);
    cover  (v_a.key[0] != v_b.key[0]);     // the keys really can differ
  end
`endif
endmodule
`default_nettype wire

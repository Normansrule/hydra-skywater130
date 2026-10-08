// =============================================================================
// key_vault_ni.sv -- non-interference: the host read port carries no key bits
// =============================================================================
// Two copies of the vault, driven with IDENTICAL control signals and
// DIFFERENT key material. If any key bit reached the host-visible outputs by
// any path -- a debug register, a mis-indexed status field, a lazy assign --
// the two copies would differ on some cycle and the proof would produce that
// cycle as a counterexample.
//
// This is worth more than asserting "rdata does not equal the key". That
// kind of assertion passes while a single XORed bit leaks, and it says
// nothing about paths the author did not think of. Non-interference makes
// no assumption about HOW a leak might happen.
//
// SCOPE OF THE RESULT, stated precisely because a security claim deserves
// it: this is an UNBOUNDED proof (k-induction, sby `mode prove`). It holds
// for every reachable state, at every cycle, for all key values and all
// command orders -- not just the first N cycles.
//
// Induction needs one extra fact: the two copies' BOOKKEEPING (which words
// are written, which slots are filled, which are sealed) is identical. That
// is true -- bookkeeping depends only on control, and control is shared --
// and it is asserted below, so the solver proves it too rather than being
// told it. Until 2026-10-07 this proof was bounded to 16 cycles, because
// stating that fact needed hierarchical references into the two copies,
// and those did not survive conversion. The vault now exposes its
// bookkeeping as proof-only output ports (f_locked, f_filled, f_seen),
// which do.
//
// It is run at two sizes: two 64-bit slots (task ni) and the SHIPPED
// configuration, four 256-bit slots written 32 bits at a time (task
// ni_full). Key material is never constrained in either, so the proof
// covers every possible key.
// =============================================================================
`default_nettype none

module key_vault_ni #(
  // Defaults are the small configuration; key_vault.sby's ni_full task
  // sets the shipped one (NSLOT 4, KW 256) with chparam.
  parameter int unsigned NSLOT = 2,
  parameter int unsigned KW    = 64,
  parameter int unsigned WW    = 32
) (
  input wire clk,
  input wire rst_n,
  // identical control for both copies
  input wire                     host_we,
  input wire [$clog2(NSLOT)-1:0] host_slot,
  input wire [$clog2(KW/WW)-1:0] host_word,
  input wire                     host_lock,
  input wire                     host_wipe,
  input wire [$clog2(NSLOT)-1:0] host_rd_slot,
  input wire                     eng_req,
  input wire [$clog2(NSLOT)-1:0] eng_slot,
  // the ONLY difference between the copies
  input wire [WW-1:0]            wdata_a,
  input wire [WW-1:0]            wdata_b
);
  wire [WW-1:0] rdata_a, rdata_b;
  wire          err_a,   err_b;
  wire          valid_a, valid_b;
  wire [KW-1:0] key_a,   key_b;
  localparam int unsigned NWORD = KW / WW;
  wire [NSLOT-1:0]       lk_a, lk_b, fl_a, fl_b;
  wire [NSLOT*NWORD-1:0] sn_a, sn_b;

  hydra_key_vault #(.NSLOT(NSLOT), .KW(KW), .WW(WW)) u_a (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_slot(host_slot), .host_word(host_word),
    .host_wdata(wdata_a), .host_lock(host_lock), .host_wipe(host_wipe),
    .host_rd_slot(host_rd_slot), .host_rdata(rdata_a), .err_locked(err_a),
    .eng_req(eng_req), .eng_slot(eng_slot), .eng_key(key_a), .eng_valid(valid_a),
    .f_locked(lk_a), .f_filled(fl_a), .f_seen(sn_a));

  hydra_key_vault #(.NSLOT(NSLOT), .KW(KW), .WW(WW)) u_b (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_slot(host_slot), .host_word(host_word),
    .host_wdata(wdata_b), .host_lock(host_lock), .host_wipe(host_wipe),
    .host_rd_slot(host_rd_slot), .host_rdata(rdata_b), .err_locked(err_b),
    .eng_req(eng_req), .eng_slot(eng_slot), .eng_key(key_b), .eng_valid(valid_b),
    .f_locked(lk_b), .f_filled(fl_b), .f_seen(sn_b));

`ifdef FORMAL
  // Reset is asserted at power-up, and the comparison starts one cycle
  // later. Before the first clock edge the two copies' registers are
  // unconstrained and differ for reasons that have nothing to do with key
  // material; asserting there would fail on noise. After the reset edge
  // both copies are in the same defined state and any later difference is
  // a real leak.
  // CLOCKED reset assumption, not `initial assume (!rst_n)`. The initial
  // form survived conversion but did not constrain the solver: the
  // counterexample showed reset never asserting, both copies starting from
  // different arbitrary register state, and a "leak" that was nothing of
  // the kind. Assuming it at the first clock edge does constrain it.
  logic started = 1'b0;
  always_ff @(posedge clk) started <= 1'b1;
  always_ff @(posedge clk) if (!started) assume (!rst_n);

  always_ff @(posedge clk) if (started) begin
    // Everything the host can see must be identical, whatever the keys are.
    assert (rdata_a == rdata_b);
    assert (err_a   == err_b);
    assert (valid_a == valid_b);

    // The induction invariant: bookkeeping is identical in both copies.
    // Proved, not assumed.
    assert (lk_a == lk_b);
    assert (fl_a == fl_b);
    assert (sn_a == sn_b);

    // Sanity: the keys really are allowed to differ, so the proof above is
    // not passing because both copies hold the same thing. Without this the
    // whole exercise could be vacuous.
    cover (key_a != key_b);
  end
`endif
endmodule

`default_nettype wire

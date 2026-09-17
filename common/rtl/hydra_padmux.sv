// =============================================================================
// hydra_padmux.sv -- runtime pad function multiplexer, shared by all targets
// =============================================================================
//
// WHY THIS EXISTS
//   The three HYDRA targets have three different pin budgets for the same
//   design: a TinyTapeout tile gets 24 signal pins whatever its size, the
//   OpenFrame padframe gives 44 GPIOs to a SoC that needs 45+, and every FPGA
//   board exposes a different set of headers. Instead of three hand-edited
//   pin maps (three copies that nothing keeps honest -- the stale-anchor
//   failure pattern, sessions 135/136/178/178m), each target is GENERATED from
//   one plan by tools/hydra_bind.py, and any pad that carries more than one
//   function goes through this block.
//
// CONTRACT
//   * Each pad p has NALT alternatives. Alternative k drives pad p with
//     alt_out[p*NALT+k] / alt_oe[p*NALT+k] while sel(p) == k.
//   * A function input sees the pad only while selected; otherwise it sees
//     its idle value alt_idle[...] (e.g. 1 for a UART RX line). A deselected
//     function therefore never reads a pad that belongs to someone else.
//   * sel resets to RESET_SEL. hydra_bind.py always makes alternative 0 of
//     every pad an inert input (oe tied 0), so power-on is all-inputs.
//   * pad_oe is gated by rst_n COMBINATIONALLY. rst_n comes from
//     hydra_rst_sync (async assert), so asserting reset releases every pad
//     immediately rather than one clock later. For a motor pad that is the
//     difference between "safe" and "one more PWM edge".
//   * cfg_we writes all selects at once. A per-pad select >= NALT is illegal
//     and that pad keeps its old value (no out-of-range index, ever).
//   * cfg_lock is sticky until reset. Once locked, cfg_we is ignored. A write
//     and a lock in the same cycle apply the write, then lock, so one
//     "configure-and-lock" step is enough. Lock exists so a compromised
//     firmware cannot re-route, e.g., the debug or keystore pins after boot.
//
// VERIFICATION
//   tb/tb_hydra_padmux.sv against tb/padmux_model.py (independent, written
//   from this contract, not from the RTL), and formal/hydra_padmux.sby with
//   formal/mutate_padmux.py -- every mutation must die.
// =============================================================================
`default_nettype none

module hydra_padmux #(
  parameter int NPAD = 24,
  parameter int NALT = 4,
  parameter int SELW = (NALT > 1) ? $clog2(NALT) : 1,
  parameter logic [NPAD*SELW-1:0] RESET_SEL = '0
) (
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic                  cfg_we,
  input  logic [NPAD*SELW-1:0]  cfg_sel,
  input  logic                  cfg_lock,
  output logic [NPAD*SELW-1:0]  sel_q,
  output logic                  locked_q,

  input  logic [NPAD*NALT-1:0]  alt_out,
  input  logic [NPAD*NALT-1:0]  alt_oe,
  input  logic [NPAD*NALT-1:0]  alt_idle,
  output logic [NPAD*NALT-1:0]  alt_in,

  output logic [NPAD-1:0]       pad_out,
  output logic [NPAD-1:0]       pad_oe,
  input  logic [NPAD-1:0]       pad_in
);

  // ---------------------------------------------------------------------------
  // Select register. Per-pad legality check so an illegal code on one pad
  // does not block a legal update on another.
  // ---------------------------------------------------------------------------
  logic [NPAD*SELW-1:0] sel_d;

  always_comb begin
    sel_d = sel_q;
    if (cfg_we && !locked_q) begin
      for (int p = 0; p < NPAD; p++) begin
        if (cfg_sel[p*SELW +: SELW] < NALT)
          sel_d[p*SELW +: SELW] = cfg_sel[p*SELW +: SELW];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sel_q    <= RESET_SEL;
      locked_q <= 1'b0;
    end else begin
      sel_q    <= sel_d;
      locked_q <= locked_q | cfg_lock;
    end
  end

  // ---------------------------------------------------------------------------
  // Routing.
  // ---------------------------------------------------------------------------
  always_comb begin
    for (int p = 0; p < NPAD; p++) begin
      pad_out[p] = alt_out[p*NALT + sel_q[p*SELW +: SELW]];
      pad_oe[p]  = alt_oe [p*NALT + sel_q[p*SELW +: SELW]] & rst_n;
      for (int k = 0; k < NALT; k++) begin
        alt_in[p*NALT + k] = (sel_q[p*SELW +: SELW] == k) ? pad_in[p]
                                                          : alt_idle[p*NALT + k];
      end
    end
  end

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Properties. Kept in the RTL so they travel with it.
  // ---------------------------------------------------------------------------
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;

  // The environment: reset is asserted in the first cycle.
  always_comb if (!past_valid) assume (!rst_n);

  always_comb begin
    // P1: no pad ever holds an illegal select, so the routing never indexes
    //     outside its alternative list.
    for (int p = 0; p < NPAD; p++)
      assert (sel_q[p*SELW +: SELW] < NALT);

    // P2: reset releases every pad, combinationally.
    if (!rst_n) assert (pad_oe == '0);

    // P3: reset state.
    if (!rst_n) begin
      assert (sel_q == RESET_SEL);
      assert (!locked_q);
    end

    // P4/P5: routing equals the selected alternative; unselected inputs idle.
    for (int p = 0; p < NPAD; p++) begin
      assert (pad_out[p] == alt_out[p*NALT + sel_q[p*SELW +: SELW]]);
      if (rst_n) assert (pad_oe[p] == alt_oe[p*NALT + sel_q[p*SELW +: SELW]]);
      for (int k = 0; k < NALT; k++) begin
        if (sel_q[p*SELW +: SELW] == k) assert (alt_in[p*NALT+k] == pad_in[p]);
        else                            assert (alt_in[p*NALT+k] == alt_idle[p*NALT+k]);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (past_valid && rst_n && $past(rst_n)) begin
      // P6: lock is sticky.
      if ($past(locked_q)) assert (locked_q);
      // P7: once locked, the selection never changes.
      if ($past(locked_q)) assert (sel_q == $past(sel_q));
      // P8: without a write, the selection never changes.
      if (!$past(cfg_we)) assert (sel_q == $past(sel_q));
      // P9: a legal write while unlocked takes effect on the next edge.
      if ($past(cfg_we) && !$past(locked_q))
        for (int p = 0; p < NPAD; p++)
          if ($past(cfg_sel[p*SELW +: SELW]) < NALT)
            assert (sel_q[p*SELW +: SELW] == $past(cfg_sel[p*SELW +: SELW]));
      // P10: lock requested -> locked next cycle.
      if ($past(cfg_lock)) assert (locked_q);
    end
  end

  // Reachability: we can actually lock with a non-reset personality.
  always_ff @(posedge clk)
    if (past_valid) cover (rst_n && locked_q && sel_q != RESET_SEL);
`endif

endmodule

`default_nettype wire

// =============================================================================
// tb_v1_v2_diff.sv -- v2 in LEGACY personality must equal v1, pin for pin
// =============================================================================
// WHY: eight directed tests passing is not the same as "unchanged". This runs
// the v1 RTL (session 144, commit b179c6b) and v2 side by side on random pin
// traffic, including resets that land anywhere, and compares every output on
// every cycle.
//
// WHAT THIS DOES AND DOES NOT PROVE, since session 181:
// v2 is built here with -DHYDRA_COST_SHARED=1'b0, its five parallel cost
// engines (see the Makefile's diff target). The
// SHIPPED tile uses one shared engine walked over the five parameter rows,
// which computes the same costs in more cycles and is therefore NOT cycle
// identical to v1. This bench proves the DATAPATH is unchanged; tb_cost_mux
// proves the shared sequencer reaches the same decisions as the parallel
// engines. Neither alone is enough, which is why both exist.
//
// One documented difference: the margin nibble (uio_out[7:4]). v1 can only
// output 0 or F (see the v2 header). The relations that must still hold:
//   v1 == 0            -> v2 == 0
//   v2 not in {0, F}   -> v1 == F
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_v1_v2_diff;
  localparam int CYCLES = 400000;
  reg clk = 0, rst_n = 0;
  reg [7:0] ui_in = 0, uio_in = 0;
  wire [7:0] uo1, uio1, oe1, uo2, uio2, oe2;

  tt_um_hydra_mom_v1 v1 (.ui_in(ui_in), .uo_out(uo1), .uio_in(uio_in), .uio_out(uio1),
                         .uio_oe(oe1), .ena(1'b1), .clk(clk), .rst_n(rst_n));
  tt_um_hydra_mom    v2 (.ui_in(ui_in), .uo_out(uo2), .uio_in(uio_in), .uio_out(uio2),
                         .uio_oe(oe2), .ena(1'b1), .clk(clk), .rst_n(rst_n));

  always #27.5 clk = ~clk;

  integer i, errors = 0, disp_seen = 0, resets = 0, nib_mid = 0;
  integer seed = 179;
  reg [7:0] r;
  // v2 releases reset through a two-stage synchroniser (hydra_rst_sync);
  // v1 released it straight from the pin. So for SYNC_STAGES cycles after
  // every release, v2 is still in reset BY DESIGN and v1 is not. The
  // contract, stated rather than hidden: pins are held idle for that window
  // plus one, and outputs are not compared inside it. Everywhere else the
  // two must match pin for pin, exactly as before.
  localparam integer SYNC_STAGES = 2;
  integer since_release = 100;
  reg     prev_rst_n = 0;

  initial begin
    for (i = 0; i < CYCLES; i = i + 1) begin
      @(negedge clk);
      // ---- compare (outputs settled from the previous edge) ----
      if (i > 3 && since_release > SYNC_STAGES) begin
        if (uo1 !== uo2 || uio1[3:0] !== uio2[3:0] || oe1 !== oe2) begin
          errors = errors + 1;
          if (errors <= 10)
            $display("MISMATCH cyc %0d: uo %h/%h uio %h/%h oe %h/%h", i, uo1, uo2, uio1, uio2, oe1, oe2);
        end
        if (uio1[7:4] == 4'h0 && uio2[7:4] != 4'h0) begin
          errors = errors + 1; $display("MARGIN cyc %0d: v1 0 but v2 %h", i, uio2[7:4]);
        end
        if (uio2[7:4] != 4'h0 && uio2[7:4] != 4'hF && uio1[7:4] != 4'hF) begin
          errors = errors + 1; $display("MARGIN cyc %0d: v2 %h but v1 %h", i, uio2[7:4], uio1[7:4]);
        end
        if (uio2[7:4] != 4'h0 && uio2[7:4] != 4'hF) nib_mid = nib_mid + 1;
        if (uo1[3]) disp_seen = disp_seen + 1;
      end
      // ---- drive next ----
      r = $random(seed);
      if (r < 2 && i > 10) begin
        rst_n = 0; resets = resets + 1;
        // Anything but the register-mode strap on ui_in[7:4].
        ui_in = $random(seed);
        if (ui_in[7:4] == 4'hA) ui_in[7:4] = 4'h5;
      end else if (!prev_rst_n || since_release < SYNC_STAGES) begin
        // The window must INCLUDE the release cycle itself: the first
        // version started counting one cycle late, so random stimulus on
        // the release edge reached v1 while v2 was still in reset.
        // Inside the release window: idle pins, so v1 cannot act on
        // anything v2 is still in reset for.
        rst_n = 1;
        ui_in = 8'h00; uio_in = 8'h00;
      end else begin
        rst_n = 1;
        ui_in = $random(seed);
        // Bias: mostly shifting, sometimes go / comp, so dispatches happen.
        if (ui_in[6:5] != 2'b11) ui_in[3:2] = 2'b00;
        uio_in = $random(seed);
      end
      since_release = (rst_n && !prev_rst_n) ? 0 : since_release + 1;
      prev_rst_n    = rst_n;
    end
    $display("diff: %0d cycles, %0d resets, %0d cycles with dispatched=1, %0d mid-range margin samples",
             CYCLES, resets, disp_seen, nib_mid);
    if (disp_seen == 0) begin $display("FAIL: stimulus never produced a dispatch"); $fatal(1); end
    if (errors) begin $display("FAIL: %0d differences", errors); $fatal(1); end
    $display("PASS tb_v1_v2_diff");
    $finish;
  end
endmodule

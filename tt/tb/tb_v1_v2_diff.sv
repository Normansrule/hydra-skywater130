// =============================================================================
// tb_v1_v2_diff.sv -- v2 in LEGACY personality must equal v1, pin for pin
// =============================================================================
// WHY: eight directed tests passing is not the same as "unchanged". This runs
// the v1 RTL (session 144, commit b179c6b) and v2 side by side on random pin
// traffic, including resets that land anywhere, and compares every output on
// every cycle.
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

  initial begin
    for (i = 0; i < CYCLES; i = i + 1) begin
      @(negedge clk);
      // ---- compare (outputs settled from the previous edge) ----
      if (i > 3) begin
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
      end else begin
        rst_n = 1;
        ui_in = $random(seed);
        // Bias: mostly shifting, sometimes go / comp, so dispatches happen.
        if (ui_in[6:5] != 2'b11) ui_in[3:2] = 2'b00;
        uio_in = $random(seed);
      end
    end
    $display("diff: %0d cycles, %0d resets, %0d cycles with dispatched=1, %0d mid-range margin samples",
             CYCLES, resets, disp_seen, nib_mid);
    if (disp_seen == 0) begin $display("FAIL: stimulus never produced a dispatch"); $fatal(1); end
    if (errors) begin $display("FAIL: %0d differences", errors); $fatal(1); end
    $display("PASS tb_v1_v2_diff");
    $finish;
  end
endmodule

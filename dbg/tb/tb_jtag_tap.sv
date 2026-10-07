// =============================================================================
// tb_jtag_tap.sv -- the test access port against a model of the standard
// =============================================================================
// Replays the TMS/TDI sequence jtag_model.py produced and compares TDO on
// every single clock edge. The model was written from IEEE 1149.1's state
// diagram, not from the RTL, so a misreading of the standard shows up here
// as a disagreement rather than being copied into both.
//
// TDO is presented on the FALLING edge of TCK and sampled by the probe on
// the rising edge, so the bench samples it just before each rising edge --
// the same way real hardware on the other end of the cable would.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_jtag_tap;
  localparam int DRW = 40;

  logic tck = 0, tms = 0, tdi = 0;
  wire  tdo, tdo_oe;
  wire [DRW-1:0] user_dr;
  wire           user_update;
  wire [3:0]     ir;
  wire           in_reset;
  logic [DRW-1:0] user_capture = 40'h5A_A5_3C_C3_96;

  hydra_jtag_tap #(.DRW(DRW)) dut (
    .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo), .tdo_oe(tdo_oe),
    .user_dr(user_dr), .user_update(user_update), .user_capture(user_capture),
    .ir(ir), .in_reset(in_reset));

  // Plain `integer` and `reg`, not `int`/`logic`: converted to Verilog these
  // module-level declarations became NETS, and $fscanf cannot assign a net.
  integer      nedge, errors = 0, updates = 0, checked = 0, nupd = 0;
  reg [31:0]   idcode_exp;
  reg [DRW-1:0] cap_exp;
  reg [DRW-1:0] upd_exp [0:7];

  reg [1:0] stim_tms [0:1023];
  reg [1:0] stim_tdi [0:1023];
  reg [1:0] stim_tdo [0:1023];
  reg [1:0] stim_oe  [0:1023];

  initial begin
    integer fd, code, a, b, c, d, i;
    fd = $fopen("dbg/tb/jtag_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run jtag_model.py first"); $fatal(1); end
    code = $fscanf(fd, "%d\n", nedge);
    code = $fscanf(fd, "%h\n", idcode_exp);
    code = $fscanf(fd, "%h\n", cap_exp);
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%h\n", upd_exp[nupd]);
      if (code == 1) nupd++;
    end
    $fclose(fd);

    fd = $fopen("dbg/tb/jtag_stim.txt", "r");
    for (i = 0; i < nedge; i++) begin
      code = $fscanf(fd, "%d %d %d %d\n", a, b, c, d);
      stim_tms[i] = 2'(a); stim_tdi[i] = 2'(b); stim_tdo[i] = 2'(c);
      stim_oe[i] = 2'(d);
    end
    $fclose(fd);
  end

  // Every user-register update the hardware performs is recorded and checked
  // against the model's list, in order.
  always @(posedge tck) if (user_update) begin
    if (updates >= nupd || user_dr !== upd_exp[updates]) begin
      errors++;
      $display("FAIL update %0d: hardware %010x, model %010x",
               updates, user_dr, (updates < nupd) ? upd_exp[updates] : {DRW{1'bx}});
    end
    updates++;
  end

  initial begin #2_000_000; $display("FAIL tb_jtag_tap: watchdog"); $fatal(1); end

  integer e;
  initial begin
    #1;
    for (e = 0; e < nedge; e++) begin
      tms = stim_tms[e][0];
      tdi = stim_tdi[e][0];
      #5;
      // Sample where a probe would: settled, just before the edge. The
      // enable is checked on every edge; the DATA is only checked while the
      // port is driving, because an undriven pin carries no promise and
      // comparing it against a model value is comparing noise. Edge 0 is
      // exempt entirely -- no falling edge has happened yet, so the output
      // register has not been loaded even once.
      if (e > 0 && tdo_oe !== stim_oe[e][0]) begin
        errors++;
        if (errors < 8)
          $display("FAIL edge %0d: drive hardware %b, model %b", e, tdo_oe, stim_oe[e][0]);
      end else if (e > 0 && stim_oe[e][0]) begin
        if (tdo !== stim_tdo[e][0]) begin
          errors++;
          if (errors < 8)
            $display("FAIL edge %0d: TDO hardware %b, model %b (state %0d)",
                     e, tdo, stim_tdo[e][0], dut.st);
        end else checked++;
      end
      tck = 1; #5; tck = 0;
    end

    if (updates !== nupd) begin
      errors++;
      $display("FAIL: %0d user updates, model expected %0d", updates, nupd);
    end

    if (errors) begin
      $display("FAIL tb_jtag_tap: %0d errors over %0d edges", errors, nedge);
      $fatal(1);
    end
    $display("PASS tb_jtag_tap: %0d TCK edges bit-exact against the standard's model, %0d user updates",
             checked, updates);
    $finish;
  end
endmodule
`default_nettype wire

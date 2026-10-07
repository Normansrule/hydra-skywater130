// =============================================================================
// tb_pcr.sv -- the measurement register against hashlib, step by step
// =============================================================================
// Six extend_count, with the expected register checked after EVERY one, so a
// failure names the step that broke rather than just the final value.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_pcr;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic          extend = 0;
  logic [255:0]  meas = '0;
  wire           busy, done;
  wire [255:0]   pcr;
  wire [15:0]    extend_count;

  hydra_pcr dut (.clk(clk), .rst_n(rst_n), .extend(extend), .meas(meas),
                 .busy(busy), .done(done), .pcr(pcr), .extend_count(extend_count));

  reg [255:0] mvec [0:15], evec [0:15];
  integer n = 0, errors = 0, i, guard;

  initial begin
    integer fd, code;
    reg [255:0] v;
    fd = $fopen("sec/tb/pcr_meas.txt", "r");
    if (fd == 0) begin $display("FAIL: run pcr_model.py first"); $fatal(1); end
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%h\n", v);
      if (code == 1) begin mvec[n] = v; n = n + 1; end
    end
    $fclose(fd);
    fd = $fopen("sec/tb/pcr_exp.txt", "r");
    for (i = 0; i < n; i = i + 1) code = $fscanf(fd, "%h\n", evec[i]);
    $fclose(fd);
  end

  initial begin #5_000_000; $display("FAIL tb_pcr: watchdog"); $fatal(1); end

  initial begin
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

    if (pcr !== 256'd0) begin
      errors = errors + 1; $display("FAIL: register does not start at zero");
    end

    for (i = 0; i < n; i = i + 1) begin
      @(negedge clk); meas = mvec[i]; extend = 1;
      @(negedge clk); extend = 0;

      guard = 0;
      while (!done && guard < 4000) begin @(negedge clk); guard = guard + 1; end
      if (guard >= 4000) begin
        errors = errors + 1; $display("FAIL extend %0d: never completed", i);
      end
      @(negedge clk);

      if (pcr !== evec[i]) begin
        errors = errors + 1;
        $display("FAIL extend %0d:", i);
        $display("      hardware %064x", pcr);
        $display("      hashlib  %064x", evec[i]);
      end
      if (extend_count !== 16'(i + 1)) begin
        errors = errors + 1;
        $display("FAIL extend %0d: counter reads %0d", i, extend_count);
      end
    end

    // There is no way to set the register: the only input is a measurement,
    // and folding one in can never land on a chosen value without a
    // preimage. What CAN be checked here is that a reset clears it, which
    // is the one visible way the record goes away.
    @(negedge clk); rst_n = 0;
    repeat (2) @(negedge clk); rst_n = 1;
    @(negedge clk);
    if (pcr !== 256'd0 || extend_count !== 16'd0) begin
      errors = errors + 1;
      $display("FAIL: reset left %064x, counter %0d", pcr, extend_count);
    end

    if (errors) begin
      $display("FAIL tb_pcr: %0d errors over %0d extend_count", errors, n);
      $fatal(1);
    end
    $display("PASS tb_pcr: %0d extend_count, chain identical to hashlib, reset clears", n);
    $finish;
  end
endmodule
`default_nettype wire

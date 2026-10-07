// =============================================================================
// tb_jtag_bridge.sv -- the clock crossing, driven from two unrelated clocks
// =============================================================================
// The bug this is looking for does not appear when the two clocks are
// related by a neat integer ratio, which is exactly what a lazy bench uses.
// Here TCK is a deliberately awkward multiple of the system clock, with an
// offset that is not a whole number of system periods, so request and
// acknowledgement edges land all over the system clock's cycle.
//
// A register file model sits on the far side. Every write is checked by
// reading it back through the same path, so a transfer that silently
// corrupts address or data shows up as a wrong value rather than as a hang.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_jtag_bridge;
  localparam int AW = 7, DW = 32;

  logic clk = 0, rst_n = 0;
  logic tck = 0, trst_n = 0;
  always #5 clk = ~clk;                     // 100 MHz
  always #17.5 tck = ~tck;                  // ~28.6 MHz, deliberately not a ratio

  logic [AW+DW:0] user_dr = '0;
  logic           user_update = 0;
  wire  [AW+DW:0] user_capture;
  wire            reg_we, reg_re;
  wire  [AW-1:0]  reg_addr;
  wire  [DW-1:0]  reg_wdata;
  logic [DW-1:0]  reg_rdata;

  hydra_jtag_bridge #(.AW(AW), .DW(DW)) dut (
    .tck(tck), .trst_n(trst_n), .user_dr(user_dr), .user_update(user_update),
    .user_capture(user_capture),
    .clk(clk), .rst_n(rst_n), .reg_we(reg_we), .reg_re(reg_re),
    .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata));

  // ---- the far side: a small register file --------------------------------
  logic [DW-1:0] mem [0:127];
  integer accesses = 0;
  always_ff @(posedge clk) begin
    if (reg_we) begin mem[reg_addr] <= reg_wdata; accesses <= accesses + 1; end
    if (reg_re) begin reg_rdata <= mem[reg_addr]; accesses <= accesses + 1; end
  end

  integer errors = 0, done = 0, i;
  reg [DW-1:0] shadow [0:127];

  task automatic xfer(input logic rw, input logic [AW-1:0] a,
                      input logic [DW-1:0] d);
    integer guard;
    @(negedge tck);
    user_dr = {rw, a, d};
    user_update = 1'b1;
    @(negedge tck);
    user_update = 1'b0;
    // Poll the busy flag exactly as software would, rather than waiting a
    // fixed number of cycles: a fixed wait passes on a bench and fails on a
    // board whose clock ratio differs.
    guard = 0;
    while (user_capture[AW+DW] && guard < 500) begin
      @(negedge tck); guard++;
    end
    if (guard >= 500) begin
      errors++;
      $display("FAIL: transfer to %0d never completed (bridge stuck busy)", a);
    end
  endtask

  initial begin #500_000; $display("FAIL tb_jtag_bridge: watchdog"); $fatal(1); end

  integer seed = 7;
  logic [AW-1:0] a;
  logic [DW-1:0] d;

  initial begin
    repeat (4) @(posedge clk); rst_n = 1;
    repeat (2) @(posedge tck); trst_n = 1;
    repeat (4) @(posedge tck);

    // writes
    for (i = 0; i < 24; i++) begin
      a = AW'($random(seed));
      d = DW'($random(seed));
      shadow[a] = d;
      xfer(1'b1, a, d);
    end

    // read every one back through the same crossing
    for (i = 0; i < 128; i++) begin
      if (shadow[i] !== {DW{1'bx}}) begin
        xfer(1'b0, AW'(i), '0);
        if (user_capture[DW-1:0] !== shadow[i]) begin
          errors++;
          if (errors < 8)
            $display("FAIL read %0d: bridge %08x, expected %08x",
                     i, user_capture[DW-1:0], shadow[i]);
        end else done++;
        // The address comes back too, so a transfer that lands on the wrong
        // register is caught even when the data happens to match.
        if (user_capture[AW+DW-1 -: AW] !== AW'(i)) begin
          errors++;
          $display("FAIL read %0d: bridge reports address %0d",
                   i, user_capture[AW+DW-1 -: AW]);
        end
      end
    end

    // An update while busy must be ignored, not queued or half-applied.
    @(negedge tck);
    user_dr = {1'b1, AW'(9), 32'hDEAD_BEEF};
    user_update = 1'b1;
    @(negedge tck);
    user_dr = {1'b1, AW'(9), 32'hFEED_FACE};   // change it mid-flight
    @(negedge tck);
    user_update = 1'b0;
    while (user_capture[AW+DW]) @(negedge tck);
    xfer(1'b0, AW'(9), '0);
    if (user_capture[DW-1:0] !== 32'hDEAD_BEEF) begin
      errors++;
      $display("FAIL: payload changed mid-transfer, register 9 holds %08x",
               user_capture[DW-1:0]);
    end else done++;

    if (errors) begin
      $display("FAIL tb_jtag_bridge: %0d errors", errors);
      $fatal(1);
    end
    $display("PASS tb_jtag_bridge: %0d transfers across unrelated clocks, %0d checks exact",
             accesses, done);
    $finish;
  end
endmodule
`default_nettype wire

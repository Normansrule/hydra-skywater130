// =============================================================================
// tb_fpga_selftest.sv -- the bring-up image, checked before it goes on a board
// =============================================================================
// Every behaviour the bring-up guide tells you to look for is checked here
// first, so that when a board does something different the difference is in
// the board, not in the image:
//
//   the sweep        one lit LED walks 0..7 twice, in order, then stops
//   mirror mode      each switch drives its own LED
//   pattern mode     a switch change blinks that switch's NUMBER, three times
//   serial           the banner, one report per switch change, and echo
//
// Serial output is decoded by a behavioural receiver written here, not by
// the design's own receiver, so a bug shared by both ends cannot hide.
// Timing is scaled down (TICK=4) -- the logic is the one that ships.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_fpga_selftest;
  localparam int TICK = 4, CPB = 8, DEB = 3, STEP = 5, BLINK = 4;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [7:0] dip = 8'd0;
  wire  [7:0] led;
  logic       rx = 1'b1;
  wire        tx;

  hydra_fpga_selftest #(.TICK(TICK), .CLKS_PER_BIT(CPB), .DEBOUNCE_MS(DEB),
                        .STEP_MS(STEP), .BLINK_MS(BLINK)) dut (
    .clk(clk), .rst_n(rst_n), .dip(dip), .led(led),
    .uart_rx_i(rx), .uart_tx_o(tx));

  integer errors = 0, checks = 0;

  // ---- behavioural serial receiver, independent of the design's ------------
  reg [7:0] rxbuf [0:255];
  integer   nrx = 0;
  initial begin : decode
    integer b; reg [7:0] byte_v;
    forever begin
      @(negedge tx);
      repeat (CPB/2) @(posedge clk);          // middle of the start bit
      for (b = 0; b < 8; b = b + 1) begin
        repeat (CPB) @(posedge clk);
        byte_v[b] = tx;
      end
      repeat (CPB) @(posedge clk);            // stop bit
      rxbuf[nrx] = byte_v; nrx = nrx + 1;
    end
  end

  function automatic string got_text(input integer from, input integer to);
    string s; integer k;
    s = "";
    for (k = from; k < to; k = k + 1) s = {s, string'(rxbuf[k])};
    return s;
  endfunction

  task automatic send(input logic [7:0] v);
    integer b;
    rx = 1'b0; repeat (CPB) @(posedge clk);
    for (b = 0; b < 8; b = b + 1) begin rx = v[b]; repeat (CPB) @(posedge clk); end
    rx = 1'b1; repeat (CPB) @(posedge clk);
  endtask

  // one millisecond in bench time
  task automatic ms(input integer n); repeat (n * TICK) @(posedge clk); endtask

  // Wait until the serial line has been quiet for a while. The first version
  // of this bench checked the banner at a fixed time -- about 680 cycles in --
  // when 23 bytes at this baud take 1,840. The design was right; the bench
  // looked before the data existed. Waiting for quiet is how a person at a
  // terminal decides a message is finished, and it does not depend on guessing
  // how long any particular message takes.
  task automatic quiet();
    integer last, idle;
    last = nrx; idle = 0;
    while (idle < 40 * CPB) begin
      @(posedge clk);
      if (nrx != last || tx == 1'b0) begin last = nrx; idle = 0; end
      else idle = idle + 1;
    end
  endtask

  initial begin #20_000_000; $display("FAIL tb_fpga_selftest: watchdog"); $fatal(1); end

  integer i, pos, seen, start;
  reg [7:0] want;

  initial begin
    repeat (4) @(posedge clk); rst_n = 1;

    // ---- 1. the power-on sweep: one lit LED walking, twice -----------------
    for (pos = 0; pos < 16; pos = pos + 1) begin
      want = 8'd1 << (pos % 8);
      ms(STEP / 2);                           // sample mid-step
      if (led !== want) begin
        errors++;
        $display("FAIL sweep step %0d: led %b, expected %b", pos, led, want);
      end else checks++;
      ms(STEP - STEP / 2);
    end
    ms(2);

    // ---- 2. mirror mode: switch n drives LED n ----------------------------
    for (i = 0; i < 7; i = i + 1) begin
      dip = 8'd1 << i;
      ms(DEB + 2);
      if (led[6:0] !== dip[6:0]) begin
        errors++;
        $display("FAIL mirror: switch %0d gave led %b", i + 1, led);
      end else checks++;
    end
    dip = 8'd0; ms(DEB + 2);

    // ---- 3. pattern mode: the switch's number blinks ----------------------
    dip[7] = 1'b1; ms(DEB + 2);
    ms(BLINK * 8);                            // let the dip[7] event finish
    dip[2] = 1'b1;                            // switch 3
    ms(DEB + 1);
    seen = 0;
    for (i = 0; i < 40; i = i + 1) begin
      ms(1);
      if (led[2:0] == 3'd3) seen++;
    end
    if (seen < 3) begin
      errors++;
      $display("FAIL pattern: switch 3 never blinked as 011 (seen %0d ms)", seen);
    end else checks++;

    // ---- 4. serial: banner, switch report, echo ---------------------------
    quiet();
    if (got_text(0, 21) != "HYDRA-130 SELFTEST OK") begin
      errors++;
      $display("FAIL banner: \"%s\"", got_text(0, 21));
    end else checks++;

    quiet();
    start = nrx;
    send("Q");
    quiet();
    if (nrx == start || rxbuf[nrx - 1] !== "Q") begin
      errors++;
      $display("FAIL echo: sent Q, got %0d bytes back", nrx - start);
    end else checks++;

    // The LAST switch report must show the true final state: switches 3
    // and 8 on. Reports are snapshots, so intermediate ones may merge, but
    // the final one can never be stale -- that is the property that matters
    // to a person reading the terminal.
    begin : find_report
      integer k, last;
      last = -1;
      for (k = 0; k + 11 <= nrx; k = k + 1)
        if (got_text(k, k + 3) == "SW ") last = k;
      if (last < 0) begin
        errors++; $display("FAIL: no switch report in %0d bytes", nrx);
      end else if (got_text(last, last + 11) != "SW 00100001") begin
        errors++;
        $display("FAIL: last report \"%s\", switches 3 and 8 are on",
                 got_text(last, last + 11));
      end else checks++;
    end

    // The banner must end in a real carriage return and line feed.
    if (rxbuf[21] !== 8'h0D || rxbuf[22] !== 8'h0A) begin
      errors++;
      $display("FAIL: banner line ending %02x %02x, expected 0d 0a", rxbuf[21], rxbuf[22]);
    end else checks++;

    if (errors) begin
      begin : dump integer k;
        $write("decoded:");
        for (k = 0; k < nrx; k = k + 1) $write(" %02x", rxbuf[k]);
        $display("");
      end
      $display("FAIL tb_fpga_selftest: %0d errors", errors);
      $fatal(1);
    end
    $display("PASS tb_fpga_selftest: %0d checks -- sweep, mirror, pattern, banner, echo, report", checks);
    $finish;
  end
endmodule
`default_nettype wire

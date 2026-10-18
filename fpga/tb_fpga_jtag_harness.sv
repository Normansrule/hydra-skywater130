// =============================================================================
// tb_fpga_jtag_harness.sv -- two host paths into one tile, each on its own
// =============================================================================
// WHY: the Basys 3 image (plans/basys3.yaml) gives the tile a second host,
// the JTAG test port. "Two independent ways in" is only worth something if
// each works alone and neither sees the other's traffic. This bench is both
// PCs at once: one speaks UART, the other drives the four probe pins bit by
// bit, the way a probe does. Nothing below the pins is reached into.
//
//   1. JTAG alone: IDCODE after reset, the user register's ID word, then the
//      register personality's ID and the SIMD/TPU crossover over JTAG
//   2. UART alone, same image: the same ID and crossover
//   3. separation: a UART reply never lands in the JTAG queue, a JTAG reply
//      never appears on the serial line, and a UART byte arriving in the
//      middle of a JTAG command is dropped without disturbing it
//   4. unknown commands are refused on both paths (EE cmd)
// Expected values are the ones tb_fpga_harness checks (test.py's
// build_descriptor constants), not values read back from this design.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_fpga_jtag_harness;
  localparam int CPB = 16;
  localparam logic [127:0] SMALL = 128'h30a00080008000800006000000000000;
  localparam logic [127:0] LARGE = 128'h30a00100010001000018000000000000;
  localparam logic [31:0]  IDCODE = 32'h1130_001D;
  localparam logic [31:0]  HJB_ID = 32'h484A_4231;
  localparam logic [31:0]  TILE_ID = 32'h48594D32;     // "HYM2", as tb_fpga_harness

  logic clk = 0, rst_n = 0, rx = 1;
  logic tck = 0, tms = 1, tdi = 0;
  wire  tx, regm, tdo;
  wire [7:0] uo, uio;
  always #10 clk = ~clk;                               // 50 MHz system clock

  hydra_fpga_tt_jtag_harness #(.CLKS_PER_BIT(CPB), .HALF(8)) dut (
    .clk(clk), .rst_n(rst_n), .uart_rx_i(rx), .uart_tx_o(tx),
    .jtag_tck(tck), .jtag_tms(tms), .jtag_tdi(tdi), .jtag_tdo(tdo),
    .uo_mirror(uo), .uio_mirror(uio), .reg_mode_o(regm));

  integer errors = 0, checks = 0;
  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin errors++; $display("FAIL: %s", what); end
  endtask

  initial begin #400_000_000; $display("FAIL tb_fpga_jtag_harness: watchdog"); $fatal(1); end

  // ---------------------------------------------------------------- UART PC
  task automatic usend(input logic [7:0] b);
    rx = 0; repeat (CPB) @(posedge clk);
    for (int i = 0; i < 8; i++) begin rx = b[i]; repeat (CPB) @(posedge clk); end
    rx = 1; repeat (CPB) @(posedge clk);
  endtask

  task automatic urecv(output logic [7:0] b);
    int t;
    t = 0;
    while (tx === 1'b1) begin
      @(posedge clk); t++;
      if (t > 200000) begin $display("FAIL: UART reply timeout"); $fatal(1); end
    end
    repeat (CPB / 2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin repeat (CPB) @(posedge clk); b[i] = tx; end
    repeat (CPB) @(posedge clk);
  endtask

  // ---------------------------------------------------------------- JTAG PC
  // TCK period 170 ns: not a multiple of the 20 ns system clock, and well
  // under clk/4, so every request is finished before the next scan's
  // capture (the host rule the busy bit lets software check).
  task automatic tclk(input logic m, input logic d, output logic o);
    tms = m; tdi = d;
    #85 tck = 1;
    o = tdo;                        // TDO changed on the falling edge; sample on the rise
    #85 tck = 0;
  endtask
  task automatic tclk_(input logic m);
    logic o; tclk(m, 1'b0, o);
  endtask

  task automatic tap_reset();
    for (int i = 0; i < 6; i++) tclk_(1'b1);           // Test-Logic-Reset from anywhere
    tclk_(1'b0);                                       // Run-Test/Idle
  endtask

  // Shift an instruction; ends in Run-Test/Idle.
  task automatic shift_ir(input logic [3:0] v);
    logic o;
    tclk_(1); tclk_(1); tclk_(0); tclk_(0);            // Select-DR, Select-IR, Capture-IR, Shift-IR
    for (int i = 0; i < 4; i++) tclk(i == 3, v[i], o); // last bit leaves via Exit1-IR
    tclk_(1); tclk_(0);                                // Update-IR, Run-Test/Idle
  endtask

  // One DR scan of n bits, LSB first; returns what was captured.
  task automatic shift_dr(input int n, input logic [63:0] din, output logic [63:0] dout);
    logic o;
    dout = '0;
    tclk_(1); tclk_(0); tclk_(0);                      // Select-DR, Capture-DR, Shift-DR
    for (int i = 0; i < n; i++) begin
      tclk(i == n - 1, din[i], o);
      dout[i] = o;
    end
    tclk_(1); tclk_(0);                                // Update-DR, Run-Test/Idle
    // Idle clocks in Run-Test/Idle, as a probe's "runtest" gives: the update
    // reaches the crossing on the next TCK edge, and the acknowledgement
    // needs two more to come back. Without them the next capture can still
    // see busy -- which user_scan reports as a protocol error.
    repeat (6) tclk_(0);
  endtask

  // The user register: {rw, addr[6:0], data[31:0]} in, {busy, addr, rdata} out.
  // A scan's capture shows the result of the PREVIOUS request; its update
  // issues this one. busy at capture time must be 0, or the request just
  // shifted in may be dropped.
  task automatic user_scan(input logic rw, input logic [6:0] a, input logic [31:0] d,
                           output logic [39:0] cap);
    logic [63:0] o;
    shift_dr(40, {24'd0, rw, a, d}, o);
    cap = o[39:0];
    check(cap[39] == 1'b0, "JTAG request issued while the bridge was busy");
  endtask

  task automatic jsend(input logic [7:0] b);
    logic [39:0] c;
    user_scan(1'b1, 7'h01, {24'd0, b}, c);
  endtask

  // Pop exactly n reply bytes. Pops are pipelined: each scan captures the
  // previous pop's result and issues the next pop. An empty capture means
  // the reply is still being produced (an SPI frame takes a while), so the
  // host simply asks again. The pop issued by the scan that captured the
  // last byte is checked too: it must find the queue empty, so a reply
  // longer than expected is caught rather than silently discarded.
  logic [7:0] jq [64];
  task automatic jrecv(input int n);
    logic [39:0] c;
    int got, tries;
    got = 0; tries = 0;
    user_scan(1'b0, 7'h02, 32'd0, c);
    while (got < n) begin
      user_scan(1'b0, 7'h02, 32'd0, c);
      if (c[31]) begin jq[got] = c[7:0]; got++; end
      else if (++tries > 2000) begin
        $display("FAIL: JTAG reply timeout after %0d of %0d bytes", got, n); $fatal(1);
      end
    end
    user_scan(1'b0, 7'h00, 32'd0, c);
    check(c[31] == 1'b0, $sformatf("JTAG reply longer than %0d bytes", n));
  endtask

  // Count of reply bytes waiting, without popping (a pop of an empty queue
  // returns valid = 0, so pop-and-check is used only where 0 is expected).
  task automatic jexpect_empty(input string what);
    logic [39:0] c;
    user_scan(1'b0, 7'h02, 32'd0, c);
    user_scan(1'b0, 7'h00, 32'd0, c);
    check(c[31] == 1'b0, what);
  endtask

  // ------------------------------------------------- one frame, either host
  logic [7:0] d [32];
  logic [7:0] rbuf [32];
  bit use_jtag;
  task automatic frame(input int n);
    logic [7:0] h0, h1;
    if (use_jtag) begin
      jsend(8'hA5); jsend(8'(n));
      for (int i = 0; i < n; i++) jsend(d[i]);
      jrecv(n + 2);
      h0 = jq[0]; h1 = jq[1];
      for (int i = 0; i < n; i++) rbuf[i] = jq[i + 2];
    end else begin
      usend(8'hA5); usend(8'(n));
      for (int i = 0; i < n; i++) usend(d[i]);
      urecv(h0); urecv(h1);
      for (int i = 0; i < n; i++) begin logic [7:0] t; urecv(t); rbuf[i] = t; end
    end
    check(h0 === 8'h5A && h1 === 8'(n), $sformatf("frame header %h %h over %s", h0, h1,
                                                  use_jtag ? "JTAG" : "UART"));
  endtask

  task automatic wr_wd(input logic [127:0] v);
    d[0] = 8'h01;
    for (int i = 0; i < 16; i++) d[i+1] = v[127 - 8*i -: 8];
    frame(17);
  endtask
  task automatic go();      d[0] = 8'h03; d[1] = 8'h01; frame(2); endtask
  task automatic comp(input logic [3:0] t); d[0] = 8'h04; d[1] = {4'h0, t}; frame(2); endtask
  task automatic result(output logic [2:0] eng, output logic [3:0] tag);
    d[0] = 8'h86; for (int i = 1; i < 7; i++) d[i] = 0;
    frame(7);
    eng = rbuf[1][7:5]; tag = rbuf[1][4:1];
  endtask
  task automatic read_id(output logic [31:0] id);
    d[0] = 8'h80; d[1] = 0; d[2] = 0; d[3] = 0; d[4] = 0;
    frame(5);
    id = {rbuf[1], rbuf[2], rbuf[3], rbuf[4]};
  endtask

  task automatic crossover(input string path);
    logic [2:0] es, el; logic [3:0] ts, tl;
    wr_wd(SMALL); go(); result(es, ts); comp(ts);
    wr_wd(LARGE); go(); result(el, tl); comp(tl);
    $display("%s: small -> %0d, large -> %0d", path, es, el);
    check(es === 3'd1 && el === 3'd2, {path, ": SIMD/TPU crossover wrong"});
  endtask

  // A watcher: the serial line must stay idle while only JTAG is talking.
  bit watch_tx = 0;
  integer tx_edges = 0;
  always @(negedge tx) if (watch_tx) tx_edges++;

  logic [31:0] id;
  logic [63:0] o64;
  logic [39:0] cap;
  logic [7:0]  h0, h1;

  initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (40) @(posedge clk);

    // ---- 1. JTAG alone ------------------------------------------------------
    tap_reset();
    shift_dr(32, 64'd0, o64);                          // IDCODE is selected by reset
    check(o64[31:0] === IDCODE, $sformatf("IDCODE %08x", o64[31:0]));
    shift_ir(4'h8);                                    // the user register
    user_scan(1'b0, 7'h00, 32'd0, cap);                // read the HJB ID ...
    user_scan(1'b0, 7'h00, 32'd0, cap);                // ... it arrives on the next capture
    check(cap[31:0] === HJB_ID && cap[38:32] === 7'h00,
          $sformatf("JTAG host ID %08x at %02x", cap[31:0], cap[38:32]));

    watch_tx = 1;
    use_jtag = 1;
    read_id(id);
    check(id === TILE_ID, $sformatf("tile ID over JTAG %08x", id));
    check(rbuf[0][7] === 1'b1, "status byte not ready over JTAG");
    crossover("register mode over JTAG");
    jsend(8'h42); jrecv(2);
    check(jq[0] === 8'hEE && jq[1] === 8'h42, "unknown command over JTAG");
    watch_tx = 0;
    check(tx_edges == 0, $sformatf("%0d serial start bits while only JTAG talked", tx_edges));

    // ---- 2. UART alone, same image -------------------------------------------
    use_jtag = 0;
    read_id(id);
    check(id === TILE_ID, $sformatf("tile ID over UART %08x", id));
    crossover("register mode over UART");
    usend(8'h42); urecv(h0); urecv(h1);
    check(h0 === 8'hEE && h1 === 8'h42, "unknown command over UART");
    jexpect_empty("UART replies reached the JTAG queue");

    // ---- 3. a UART byte in the middle of a JTAG command ----------------------
    // JTAG starts an ID frame; while it is half sent, the UART host sends a
    // stray command byte. The JTAG frame must complete with the right ID,
    // and the serial line must not answer.
    watch_tx = 1; tx_edges = 0;
    d[0] = 8'h80; d[1] = 0; d[2] = 0; d[3] = 0; d[4] = 0;
    // The stray byte goes in right after the command byte, where taking it
    // would turn the frame length into the wrong number (a mutation run on
    // 2026-10-17 showed a stray placed among the zero data bytes changed
    // nothing visible, so it proved nothing).
    jsend(8'hA5);
    usend(8'h42);                                      // dropped: JTAG owns the command
    jsend(8'd5); jsend(d[0]); jsend(d[1]); jsend(d[2]); jsend(d[3]); jsend(d[4]);
    jrecv(7);
    check(jq[0] === 8'h5A && jq[1] === 8'd5 && {jq[3], jq[4], jq[5], jq[6]} === TILE_ID,
          "JTAG frame disturbed by a stray UART byte");
    repeat (CPB * 30) @(posedge clk);
    watch_tx = 0;
    check(tx_edges == 0, "the serial line answered a byte sent during a JTAG command");

    // and the UART path still works afterwards
    use_jtag = 0;
    read_id(id);
    check(id === TILE_ID, "UART after the interleave");

    if (errors) begin $display("FAIL tb_fpga_jtag_harness: %0d of %0d checks", errors, checks); $fatal(1); end
    $display("PASS tb_fpga_jtag_harness: %0d checks, UART and JTAG each alone and together", checks);
    $finish;
  end
endmodule

`default_nettype wire

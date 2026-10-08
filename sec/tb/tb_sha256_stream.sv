// =============================================================================
// tb_sha256_stream.sv -- hardware-padded SHA-256 against hashlib
// =============================================================================
// Raw message bytes in, digest out; the hardware pads. 140 messages of every
// length from 0 to 130 bytes plus the boundaries further in, each compared
// with Python's hashlib. in_valid is dropped at random so the handshake is
// exercised, not just the happy path. Then the protocol errors: a short word
// without in_last must abandon the message, and nothing may be accepted
// after in_last.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_sha256_stream;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        start = 0, in_valid = 0, in_last = 0;
  logic [31:0] in_data = 0;
  logic [2:0]  in_bytes = 0;
  wire         in_ready, busy, done, err;
  wire [255:0] digest;
  wire [63:0]  msg_bits;

  hydra_sha256_stream dut (.clk(clk), .rst_n(rst_n), .start(start),
    .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
    .in_bytes(in_bytes), .in_last(in_last), .busy(busy), .done(done),
    .digest(digest), .err(err), .msg_bits(msg_bits));

  reg [31:0]  words [0:4095];
  integer     mlen [0:255], mnw [0:255], mlast [0:255];
  reg [255:0] expd [0:255];
  integer     nmsg = 0, errors = 0, checked = 0;

  initial begin
    integer fd, code, a, b, c;
    reg [255:0] d;
    fd = $fopen("sec/tb/sha256_stream_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run sha256_stream_model.py first"); $fatal(1); end
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d %d %h\n", a, b, c, d);
      if (code == 4) begin mlen[nmsg] = a; mnw[nmsg] = b; mlast[nmsg] = c; expd[nmsg] = d; nmsg = nmsg + 1; end
    end
    $fclose(fd);
    $readmemh("sec/tb/sha256_stream_words.hex", words);
  end

  initial begin #40_000_000; $display("FAIL tb_sha256_stream: watchdog"); $fatal(1); end

  // Present one word and hold it until it is taken.
  task automatic send(input [31:0] d, input [2:0] nb, input lst);
    @(negedge clk);
    while ($urandom % 4 == 0) begin in_valid = 0; @(negedge clk); end   // random gaps
    in_valid = 1; in_data = d; in_bytes = nb; in_last = lst;
    @(posedge clk); while (!in_ready) @(posedge clk);
    @(negedge clk); in_valid = 0; in_last = 0;
  endtask

  integer m, i, base, cyc;
  initial begin
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
    base = 0;
    for (m = 0; m < nmsg; m = m + 1) begin
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      for (i = 0; i < mnw[m]; i = i + 1)
        send(words[base + i], (i == mnw[m] - 1) ? mlast[m][2:0] : 3'd4, i == mnw[m] - 1);
      cyc = 0;
      while (!done) begin @(negedge clk); cyc = cyc + 1; if (cyc > 2000) begin $display("FAIL: no done for %0d bytes", mlen[m]); $fatal(1); end end
      if (digest !== expd[m] || msg_bits !== 64'(mlen[m]) * 8) begin
        errors = errors + 1;
        $display("FAIL %0d bytes: hardware %064x bits %0d", mlen[m], digest, msg_bits);
        $display("              hashlib  %064x", expd[m]);
      end else checked = checked + 1;
      base = base + mnw[m];
    end

    // ---- protocol: a short word without in_last abandons the message -------
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    send(32'hdeadbeef, 3'd4, 1'b0);
    send(32'h01020304, 3'd2, 1'b0);
    repeat (5) @(negedge clk);
    if (!err || busy || done || digest !== '0) begin errors = errors + 1; $display("FAIL: short word without in_last was not rejected"); end

    // ---- protocol: nothing is accepted after in_last -------------------------
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    send(32'h61626300, 3'd3, 1'b1);                 // "abc"
    in_valid = 1; in_data = 32'hffffffff; in_bytes = 3'd4;
    repeat (200) begin @(negedge clk); if (in_ready) begin errors = errors + 1; $display("FAIL: in_ready after in_last"); end end
    in_valid = 0;
    if (digest !== 256'hba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad) begin
      errors = errors + 1; $display("FAIL: abc after a held in_valid: %064x", digest);
    end

    if (errors) begin $display("FAIL tb_sha256_stream: %0d errors", errors); $fatal(1); end
    $display("PASS tb_sha256_stream: %0d messages (0-130 bytes and boundaries to 1000) identical to hashlib; protocol errors rejected", checked);
    $finish;
  end
endmodule
`default_nettype wire

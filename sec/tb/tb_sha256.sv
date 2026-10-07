// =============================================================================
// tb_sha256.sv -- the hash engine against hashlib
// =============================================================================
// Seven messages, chosen to straddle the boundaries where hash engines
// break: empty, the published short vector, 55 bytes (the longest that
// still fits one block), 56 bytes (the first that needs two), exactly one
// block, and a five-block message containing every byte value.
//
// The expected digests come from Python's hashlib. A disagreement here
// means the hardware is wrong -- there is no second interpretation.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_sha256;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic         init = 0, w_we = 0, go = 0;
  logic [3:0]   w_addr = 0;
  logic [31:0]  w_data = 0;
  wire          busy, done;
  wire [255:0]  digest;

  hydra_sha256 dut (.clk(clk), .rst_n(rst_n), .init(init),
                    .w_we(w_we), .w_addr(w_addr), .w_data(w_data),
                    .go(go), .busy(busy), .done(done), .digest(digest));

  reg [31:0]  blocks [0:2047];
  integer     nblk [0:15];
  reg [255:0] expd [0:15];
  integer     ncase = 0, errors = 0, checked = 0;

  initial begin
    integer fd, code, nb, i;
    reg [255:0] d;
    fd = $fopen("sec/tb/sha256_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run sha256_model.py first"); $fatal(1); end
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %h\n", nb, d);
      if (code == 2) begin nblk[ncase] = nb; expd[ncase] = d; ncase = ncase + 1; end
    end
    $fclose(fd);
    $readmemh("sec/tb/sha256_blocks.hex", blocks);
  end

  initial begin #2_000_000; $display("FAIL tb_sha256: watchdog"); $fatal(1); end

  integer c, b, i2, base;
  initial begin
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
    base = 0;

    for (c = 0; c < ncase; c = c + 1) begin
      // A fresh message starts from the standard initial state; the blocks
      // of ONE message chain, which is the whole point of the feed-forward.
      @(negedge clk); init = 1; @(negedge clk); init = 0;

      for (b = 0; b < nblk[c]; b = b + 1) begin
        for (i2 = 0; i2 < 16; i2 = i2 + 1) begin
          @(negedge clk);
          w_we = 1; w_addr = i2[3:0]; w_data = blocks[base + b*16 + i2];
        end
        @(negedge clk); w_we = 0;
        @(negedge clk); go = 1;
        @(negedge clk); go = 0;
        while (!done) @(negedge clk);
        @(negedge clk);
      end

      if (digest !== expd[c]) begin
        errors = errors + 1;
        $display("FAIL case %0d (%0d blocks):", c, nblk[c]);
        $display("      hardware %064x", digest);
        $display("      hashlib  %064x", expd[c]);
      end else checked = checked + 1;

      base = base + nblk[c] * 16;
    end

    if (errors) begin
      $display("FAIL tb_sha256: %0d of %0d messages wrong", errors, ncase);
      $fatal(1);
    end
    $display("PASS tb_sha256: %0d messages, digests identical to hashlib", checked);
    $finish;
  end
endmodule
`default_nettype wire

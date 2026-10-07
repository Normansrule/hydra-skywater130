// =============================================================================
// tb_fpga_mem.sv -- the whole path over the serial port
// =============================================================================
// Host bytes in, host bytes out, everything real in between:
//
//   'M' writes the two operand banks
//   the register map writes a descriptor carrying the bank addresses
//   the crossbar dispatches it, the streamer feeds the array from memory
//   the results are written back to the C bank
//   'R' reads them out and they match mem/tb/dma_model.py
//
// This is the test that would have caught every integration fault found in
// the last four sessions, because it crosses every boundary at once.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_fpga_mem;
  localparam int CPB = 4;                 // short bit period: this is a bench
  localparam int N = 4;

  logic clk = 0, rst_n = 0;
  logic uart_rx = 1;
  wire  uart_tx;
  logic [1:0] profile = 2'b00;
  wire  [7:0] uo_mirror, uio_mirror;
  wire        reg_mode;
  int errors = 0;

  always #5 clk = ~clk;

  hydra_fpga_mem_harness #(.CLKS_PER_BIT(CPB), .HALF(4)) dut (
    .clk(clk), .rst_n(rst_n), .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
    .profile(profile), .uo_mirror(uo_mirror), .uio_mirror(uio_mirror),
    .reg_mode_o(reg_mode));

  // ---- serial line --------------------------------------------------------
  task automatic send(input logic [7:0] b);
    uart_rx = 0;
    repeat (CPB) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      uart_rx = b[i];
      repeat (CPB) @(posedge clk);
    end
    uart_rx = 1;
    repeat (CPB * 2) @(posedge clk);
  endtask

  // No default argument: Icarus requires every task port to be passed.
  task automatic recv(output logic [7:0] b);
    localparam int limit = 400000;
    int t;
    t = 0;
    while (uart_tx !== 1'b0 && t < limit) begin @(posedge clk); t++; end
    if (t >= limit) begin
      errors++; $display("FAIL: no reply from the board"); b = 8'hXX; return;
    end
    repeat (CPB + CPB/2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      b[i] = uart_tx;
      repeat (CPB) @(posedge clk);
    end
    repeat (CPB) @(posedge clk);
  endtask

  // ---- commands -----------------------------------------------------------
  task automatic mem_write(input logic [1:0] bank, input int addr,
                           input logic [31:0] data);
    logic [7:0] r0, r1;
    send(8'h4D); send({6'd0, bank});
    send(addr[15:8]); send(addr[7:0]);
    send(data[31:24]); send(data[23:16]); send(data[15:8]); send(data[7:0]);
    recv(r0); recv(r1);
    if (r0 !== 8'hB2) begin
      errors++; $display("FAIL: write not acknowledged (%02x)", r0);
    end
  endtask

  task automatic mem_read(input int addr, output logic [31:0] data);
    logic [7:0] r0, b3, b2, b1, b0;
    send(8'h52); send(addr[15:8]); send(addr[7:0]);
    recv(r0); recv(b3); recv(b2); recv(b1); recv(b0);
    if (r0 !== 8'hA6) begin
      errors++; $display("FAIL: read not answered (%02x)", r0);
    end
    data = {b3, b2, b1, b0};
  endtask

  // register-map access through the bridge's SPI command (0xA5)
  logic [7:0] spi_reply [34];
  task automatic spi(input int n, input logic [7:0] d [32]);
    logic [7:0] r0, cnt, tmp;
    send(8'hA5); send(8'(n));
    for (int i = 0; i < n; i++) send(d[i]);
    recv(r0); recv(cnt);
    if (r0 !== 8'h5A) begin
      errors++; $display("FAIL: SPI command refused (%02x)", r0);
    end
    for (int i = 0; i < n; i++) begin recv(tmp); spi_reply[i] = tmp; end
  endtask

  logic [7:0] frame [32];
  task automatic wr_reg(input logic [6:0] a, input int n, input logic [127:0] v);
    frame[0] = {1'b0, a};
    for (int i = 0; i < n; i++) frame[i+1] = v[(n-1-i)*8 +: 8];
    spi(n+1, frame);
  endtask
  task automatic rd_reg(input logic [6:0] a, input int n, output logic [127:0] v);
    frame[0] = {1'b1, a};
    for (int i = 1; i <= n; i++) frame[i] = 8'h00;
    spi(n+1, frame);
    v = '0;
    for (int i = 0; i < n; i++) v = (v << 8) | spi_reply[i+1];
  endtask

  // ---- vectors ------------------------------------------------------------
  logic [31:0] awords [2048], bwords [2048], expv [512];
  int mm [16], nn [16], kk [16], bb [16];
  int ncases;

  initial begin
    int fd, code, m, n, k, base;
    fd = $fopen("mem/tb/dma_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run mem/tb/dma_model.py first"); $fatal(1); end
    ncases = 0;
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d %d %d\n", m, n, k, base);
      if (code == 4) begin
        mm[ncases]=m; nn[ncases]=n; kk[ncases]=k; bb[ncases]=base; ncases++;
      end
    end
    $fclose(fd);
    $readmemh("mem/tb/dma_a.hex", awords);
    $readmemh("mem/tb/dma_b.hex", bwords);
    $readmemh("mem/tb/dma_exp.hex", expv);
  end

  initial begin #200_000_000; $display("FAIL tb_fpga_mem: watchdog"); $fatal(1); end

  logic [127:0] v, desc;
  logic [31:0]  got;
  int c, i;

  initial begin
    repeat (20) @(posedge clk); rst_n = 1;
    repeat (2000) @(posedge clk);          // the bridge holds reset a while

    // identity first: if this is wrong nothing after it means anything
    rd_reg(7'h00, 4, v);
    if (v[31:0] !== 32'h48594D32) begin
      errors++; $display("FAIL: identity %08x over the serial port", v[31:0]);
    end

    // one job is enough for an end-to-end test; the unit benches cover the rest
    c = 0;
    for (i = 0; i < kk[c]; i++) begin
      mem_write(2'd0, bb[c] + i, awords[bb[c] + i]);
      mem_write(2'd1, bb[c] + i, bwords[bb[c] + i]);
    end
    $display("loaded %0d operand slices over the serial port", kk[c]);

    // retune the array so the dispatcher will choose it for a small tile
    wr_reg(7'h0B, 6, {2'b00, 3'd2, 4'd7, 12'd2, 4'd5, 8'd2, 6'b000011, 9'b000011000});

    desc = '0;
    desc[127:124] = 4'd3;                  // GEMM
    desc[123:121] = 3'd0;                  // INT8
    desc[116:101] = 16'(mm[c]);
    desc[100:85]  = 16'(nn[c]);
    desc[84:69]   = 16'(kk[c]);
    desc[3  +: 10] = 10'(bb[c]);
    desc[13 +: 10] = 10'(bb[c]);
    desc[23 +: 10] = 10'd0;                // results at the start of C
    wr_reg(7'h01, 16, desc);
    wr_reg(7'h03, 1, 128'h01);             // GO

    rd_reg(7'h06, 6, v);
    if (v[47:45] !== 3'd2) begin
      errors++; $display("FAIL: dispatched to engine %0d, not the array", v[47:45]);
    end
    for (int w = 0; w < 40; w++) begin
      rd_reg(7'h09, 2, v);
      if (v[15:0] == 0) break;
    end

    for (i = 0; i < N*N; i++) begin
      mem_read(i, got);
      if (got !== expv[i]) begin
        errors++;
        if (errors < 8)
          $display("FAIL element %0d: board says %08x, model says %08x",
                   i, got, expv[i]);
      end
    end

    if (errors) begin
      $display("FAIL tb_fpga_mem: %0d errors", errors); $fatal(1);
    end
    $display("PASS tb_fpga_mem: matrices in over the serial port, %0d results out, all correct",
             N*N);
    $finish;
  end
endmodule
`default_nettype wire

// =============================================================================
// tb_uart_baud.sv -- the board's serial port against an independently timed host
// =============================================================================
// Audit R4 (2026-10-11). The UART used to be checked only against another
// copy of itself, sharing its divisor -- so a wrong divisor could never show.
// Here the host is a behavioural model timed in nanoseconds from the baud
// rate alone, with its own oscillator offset; the design runs at the plan's
// real system clock with the divisor tools/hydra_bind.py generated for it.
//
//   +define+F_HZ=<system clock>  +define+DIV=<clocks per bit>  +define+PPM=<host offset>
//
// Both directions, 256 bytes each, back to back with one stop bit (the
// tightest framing a host can send): every byte must arrive intact.
// =============================================================================
`timescale 1ps/1ps
`default_nettype none
`ifndef F_HZ
  `define F_HZ 12500000
`endif
`ifndef DIV
  `define DIV 109
`endif
`ifndef PPM
  `define PPM 0
`endif
module tb_uart_baud;
  localparam real CLK_PS  = 1.0e12 / `F_HZ;
  localparam real BIT_PS  = (1.0e12 / 115200.0) * (1.0 + `PPM / 1.0e6);   // the HOST's bit time

  logic clk = 0, rst_n = 0;
  always #(CLK_PS / 2.0) clk = ~clk;

  logic       rx_line = 1'b1;
  wire        rx_valid;
  wire [7:0]  rx_data;
  logic       tx_start = 0;
  logic [7:0] tx_data = 0;
  wire        tx_busy, tx_line;

  hydra_fpga_uart_rx #(.CLKS_PER_BIT(`DIV)) u_rx (.clk(clk), .rst_n(rst_n), .rx_i(rx_line),
                                                  .valid(rx_valid), .data(rx_data));
  hydra_fpga_uart_tx #(.CLKS_PER_BIT(`DIV)) u_tx (.clk(clk), .rst_n(rst_n), .start(tx_start),
                                                  .data(tx_data), .busy(tx_busy), .tx_o(tx_line));

  int errors = 0, got = 0;
  logic [7:0] expect_q [$];

  // ---- host -> design ------------------------------------------------------
  task automatic host_send(input logic [7:0] b);
    rx_line = 1'b0; #(BIT_PS);
    for (int i = 0; i < 8; i++) begin rx_line = b[i]; #(BIT_PS); end
    rx_line = 1'b1; #(BIT_PS);                           // one stop bit, no idle
  endtask
  always @(posedge clk) if (rx_valid) begin
    logic [7:0] w;
    w = expect_q.pop_front();
    if (rx_data !== w) begin
      errors++; if (errors < 6) $display("FAIL host->board: got %02x, sent %02x", rx_data, w);
    end
    got++;
  end

  // ---- design -> host: the host samples mid-bit on its own clock -----------
  int hgot = 0;
  logic [7:0] sent_q [$];
  initial forever begin
    logic [7:0] b;
    @(negedge tx_line);
    #(BIT_PS / 2.0);
    if (tx_line !== 1'b0) begin errors++; $display("FAIL board->host: false start bit"); end
    for (int i = 0; i < 8; i++) begin #(BIT_PS); b[i] = tx_line; end
    #(BIT_PS);
    if (tx_line !== 1'b1) begin errors++; if (errors < 6) $display("FAIL board->host: framing error"); end
    if (b !== sent_q.pop_front()) begin errors++; if (errors < 6) $display("FAIL board->host: byte %02x", b); end
    hgot++;
  end

  initial begin
    #(2000.0 * BIT_PS * 20);
    $display("FAIL tb_uart_baud: watchdog"); $fatal(1);
  end

  initial begin
    repeat (10) @(posedge clk); rst_n = 1; repeat (10) @(posedge clk);
    for (int i = 0; i < 256; i++) begin
      expect_q.push_back(8'((i * 73) ^ (i >> 1) ^ 8'h55));
      host_send(8'((i * 73) ^ (i >> 1) ^ 8'h55));
    end
    #(4 * BIT_PS);
    for (int i = 0; i < 256; i++) begin
      @(negedge clk);
      while (tx_busy) @(negedge clk);
      tx_data = 8'(i ^ 8'hA6); sent_q.push_back(tx_data);
      tx_start = 1; @(negedge clk); tx_start = 0;
    end
    while (tx_busy) @(negedge clk);
    #(12 * BIT_PS);
    if (got != 256 || hgot != 256) begin
      errors++; $display("FAIL: %0d of 256 bytes in, %0d of 256 out", got, hgot);
    end
    if (errors) begin
      $display("FAIL tb_uart_baud: %0d errors (%0d Hz, %0d clocks per bit, host %0d ppm)",
               errors, `F_HZ, `DIV, `PPM); $fatal(1);
    end
    $display("PASS tb_uart_baud: %0d Hz / %0d clocks per bit against a 115200-baud host at %+0d ppm: 512 bytes intact",
             `F_HZ, `DIV, `PPM);
    $finish;
  end
endmodule
`default_nettype wire

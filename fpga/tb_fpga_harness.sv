// =============================================================================
// tb_fpga_harness.sv -- the FPGA harness end to end, through its UART
// =============================================================================
// WHY: the harness is what a PC talks to on the bench. This bench is that PC:
// it speaks only the UART protocol and checks the tile's answers.
//   1. register personality: ID, the SIMD/TPU crossover, retune moves TPU away
//   2. C3 00 to switch to legacy, then the v1 protocol by pin commands,
//      including the one-clock shift pulse, and the same crossover
// Descriptor constants come from test.py's build_descriptor (MSB-first pack).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_fpga_harness;
  localparam int CPB = 16;
  localparam logic [127:0] SMALL = 128'h30a00080008000800006000000000000;
  localparam logic [127:0] LARGE = 128'h30a00100010001000018000000000000;

  logic clk = 0, rst_n = 0, rx = 1;
  wire  tx, regm;
  wire [7:0] uo, uio;
  always #10 clk = ~clk;

  hydra_fpga_tt_harness #(.CLKS_PER_BIT(CPB), .HALF(8)) dut (
    .clk(clk), .rst_n(rst_n), .uart_rx_i(rx), .uart_tx_o(tx),
    .uo_mirror(uo), .uio_mirror(uio), .reg_mode_o(regm));

  integer errors = 0;

  task automatic send(input logic [7:0] b);
    rx = 0; repeat (CPB) @(posedge clk);
    for (int i = 0; i < 8; i++) begin rx = b[i]; repeat (CPB) @(posedge clk); end
    rx = 1; repeat (CPB) @(posedge clk);
  endtask

  task automatic recv(output logic [7:0] b);
    int t;
    t = 0;
    while (tx === 1'b1) begin
      @(posedge clk); t++;
      if (t > 200000) begin $display("FAIL: reply timeout"); $fatal(1); end
    end
    repeat (CPB / 2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin repeat (CPB) @(posedge clk); b[i] = tx; end
    repeat (CPB) @(posedge clk);
  endtask

  // SPI frame: returns the CIPO bytes (without the 5A N header)
  logic [7:0] rbuf [32];
  logic [7:0] d [32];
  // Icarus does not allow unpacked arrays as subroutine ports, so the frame
  // buffer `d` is module scope and tasks take only the length.
  task automatic frame(input int n);
    logic [7:0] h0, h1;
    send(8'hA5); send(8'(n));
    for (int i = 0; i < n; i++) send(d[i]);
    recv(h0); recv(h1);
    if (h0 !== 8'h5A || h1 !== 8'(n)) begin
      errors++; $display("bad frame header %h %h", h0, h1);
    end
    for (int i = 0; i < n; i++) begin logic [7:0] t; recv(t); rbuf[i] = t; end
  endtask

  task automatic wr_wd(input logic [127:0] v);
    d[0] = 8'h01;
    for (int i = 0; i < 16; i++) d[i+1] = v[127 - 8*i -: 8];
    frame(17);
  endtask
  task automatic go();
    d[0] = 8'h03; d[1] = 8'h01; frame(2);
  endtask
  task automatic comp(input logic [3:0] t);
    d[0] = 8'h04; d[1] = {4'h0, t}; frame(2);
  endtask
  task automatic result(output logic [2:0] eng, output logic [3:0] tag);
    d[0] = 8'h86; for (int i = 1; i < 7; i++) d[i] = 0;
    frame(7);
    eng = rbuf[1][7:5]; tag = rbuf[1][4:1];
  endtask

  task automatic pins(input logic [7:0] u, input bit pulse, output logic [7:0] uo_r);
    logic [7:0] h, x;
    send(pulse ? 8'h97 : 8'h96); send(u);
    recv(h); recv(uo_r); recv(x);
    if (h !== 8'h69) begin errors++; $display("bad pin reply %h", h); end
  endtask

  task automatic legacy_dispatch(input logic [127:0] v, output logic [7:0] uo_r);
    for (int i = 127; i >= 0; i--) pins({6'b0, 1'b1, v[i]}, 1, uo_r);   // sdi + shift, one clock
    pins(8'h04, 0, uo_r);        // go level
    pins(8'h00, 0, uo_r);
  endtask

  logic [2:0] eng_s, eng_l;
  logic [3:0] tag_s, tag_l;
  logic [7:0] uo_r, h0, h1;

  initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (40) @(posedge clk);

    // ---- 1. register personality (power-on default) ------------------------
    if (!regm) begin errors++; $display("harness did not power up in register mode"); end
    d[0] = 8'h80; d[1] = 0; d[2] = 0; d[3] = 0; d[4] = 0;
    frame(5);
    if ({rbuf[1], rbuf[2], rbuf[3], rbuf[4]} !== 32'h48594D32) begin
      errors++; $display("ID over UART read %h%h%h%h", rbuf[1], rbuf[2], rbuf[3], rbuf[4]);
    end
    if (!rbuf[0][7]) begin errors++; $display("status byte not ready: %h", rbuf[0]); end

    wr_wd(SMALL); go(); result(eng_s, tag_s); comp(tag_s);
    wr_wd(LARGE); go(); result(eng_l, tag_l); comp(tag_l);
    $display("register mode over UART: small -> %0d, large -> %0d", eng_s, eng_l);
    if (eng_s !== 3'd1 || eng_l !== 3'd2) begin errors++; $display("crossover wrong"); end

    // Retune: TPU t_setup = 4000 (row packing from mom_param_rom.sv)
    begin
      logic [47:0] p;
      p = {2'b0, 3'd2, 4'd7, 12'd4000, 4'd5, 8'd2, 6'b000011, 9'b000011000};
      d[0] = 8'h0B;
      for (int i = 0; i < 6; i++) d[i+1] = p[47 - 8*i -: 8];
      frame(7);
    end
    wr_wd(LARGE); go(); result(eng_l, tag_l); comp(tag_l);
    $display("after retune over UART: large -> %0d", eng_l);
    if (eng_l === 3'd2) begin errors++; $display("retune did not move the decision"); end

    // Empty frame is legal.
    send(8'hA5); send(8'h00); recv(h0); recv(h1);
    if (h0 !== 8'h5A || h1 !== 8'h00) begin errors++; $display("empty frame reply %h %h", h0, h1); end
    // Unknown command.
    send(8'h42); recv(h0); recv(h1);
    if (h0 !== 8'hEE || h1 !== 8'h42) begin errors++; $display("unknown cmd reply %h %h", h0, h1); end

    // ---- 2. legacy personality ----------------------------------------------
    send(8'hC3); send(8'h00); recv(h0); recv(h1);
    if (h0 !== 8'h3C || h1 !== 8'h00 || regm) begin errors++; $display("switch to legacy failed"); end
    pins(8'h00, 0, uo_r);
    if (!uo_r[7] || uo_r[3]) begin errors++; $display("legacy not idle after reset: %b", uo_r); end

    legacy_dispatch(SMALL, uo_r);
    $display("legacy over UART: small -> engine %0d dispatched %b", uo_r[2:0], uo_r[3]);
    if (!uo_r[3] || uo_r[2:0] !== 3'd1) begin errors++; $display("legacy small wrong"); end
    pins({uio[3:0], 4'b1000}, 0, uo_r);   // comp for the dispatched tag
    pins(8'h00, 0, uo_r);
    legacy_dispatch(LARGE, uo_r);
    $display("legacy over UART: large -> engine %0d dispatched %b", uo_r[2:0], uo_r[3]);
    if (!uo_r[3] || uo_r[2:0] !== 3'd2) begin errors++; $display("legacy large wrong"); end

    // Retune must NOT survive a personality reset: back to register mode,
    // and the large multiply goes to the TPU again.
    send(8'hC3); send(8'h01); recv(h0); recv(h1);
    wr_wd(LARGE); go(); result(eng_l, tag_l);
    if (eng_l !== 3'd2) begin errors++; $display("parameters survived a tile reset"); end

    if (errors) begin $display("FAIL tb_fpga_harness: %0d errors", errors); $fatal(1); end
    $display("PASS tb_fpga_harness");
    $finish;
  end
endmodule

`default_nettype wire

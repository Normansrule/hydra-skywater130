// =============================================================================
// tb_sys_tile_cpu.sv -- CPU, GPU and TPU on one chip, chosen by the scheduler
// =============================================================================
// Six slots: the Sixfold CPU on 0, the memory-fed array on 2, the Pixelstorm
// GPU on 5, latency models elsewhere; ABI version 2 in front. The host loads
// a real Sixfold program into the CPU through the control space and sends
// descriptors over SPI, as it would on a board.
//
//   1  AUTO, a SCALAR job          -> only the CPU can run scalar code: engine 0;
//                                     afterwards x1..x31 and TOHOST, read back
//                                     through the control space, equal Sixfold's
//                                     model
//   2  policy GPU, a SCALAR job    -> the GPU cannot: refused, dispatched nowhere
//   3  policy CPU, an INT32 GEMM   -> engine 0 although the GPU is cheaper; the
//                                     program runs again from a clean start and
//                                     gives the same registers
//   4  CPU unhealthy, SCALAR AUTO  -> no eligible engine can do it: refused,
//                                     dispatched nowhere
//   +dir=<cpu vector dir>   05_fibonacci from tools/cpu_vectors.mjs
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_sys_tile_cpu;
  localparam int HALF = 5;

  logic clk = 0, rst_n = 0;
  logic [7:0] ui = 8'b0000_0100;
  wire  [7:0] uo, uio, uio_oe;
  logic        mem_we = 0;
  logic [1:0]  mem_bank = 0;
  logic [15:0] mem_addr = 0, mem_raddr = 0;
  logic [31:0] mem_wdata = 0;
  wire  [31:0] mem_rdata;
  int errors = 0;
  always #27.5 clk = ~clk;

  hydra_sys_tile #(.NENG(6), .TPU_ENGINE(2), .GPU_ENGINE(1), .CPU_ENGINE(1), .ABI_V2(1)) dut (
    .ui_in(ui), .uo_out(uo), .uio_in(8'h00), .uio_out(uio), .uio_oe(uio_oe),
    .ena(1'b1), .clk(clk), .rst_n(rst_n),
    .dbg_checksum(), .dbg_tiles(), .dbg_simd_checksum(), .dbg_simd_jobs(),
    .mem_we(mem_we), .mem_bank(mem_bank), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_raddr(mem_raddr), .mem_rdata(mem_rdata), .mem_refused());

  logic [7:0] rbuf [24];
  logic [7:0] d [24];
  task automatic xfer(input int n);
    ui[2] = 1'b0;
    repeat (2*HALF) @(posedge clk);
    for (int i = 0; i < n; i++) begin
      logic [7:0] rx;
      for (int b = 7; b >= 0; b--) begin
        ui[1] = d[i][b];
        repeat (HALF) @(posedge clk);
        rx = {rx[6:0], uo[0]};
        ui[0] = 1'b1;
        repeat (HALF) @(posedge clk);
        ui[0] = 1'b0;
      end
      rbuf[i] = rx;
    end
    repeat (HALF) @(posedge clk);
    ui[2] = 1'b1;
    repeat (2*HALF) @(posedge clk);
  endtask
  task automatic wr(input logic [6:0] a, input int n, input logic [127:0] v);
    d[0] = {1'b0, a};
    for (int i = 0; i < n; i++) d[i+1] = v[(n-1-i)*8 +: 8];
    xfer(n+1);
  endtask
  task automatic ctl(input logic [3:0] off, input logic [31:0] w);
    @(negedge clk); mem_we = 1; mem_bank = 2'd3; mem_addr = {2'b11, 10'd0, off}; mem_wdata = w;
    @(negedge clk); mem_we = 0;
  endtask
  task automatic ctl_read(input logic [3:0] off, output logic [31:0] w);
    @(negedge clk); mem_raddr = {2'b11, 10'd0, off}; @(negedge clk); @(negedge clk); w = mem_rdata;
  endtask

  // ---- vectors -------------------------------------------------------------------
  string dir;
  reg [7:0]  img [0:65535];
  reg [63:0] want [0:31];
  reg [63:0] want_tohost;
  integer    want_cycles, fd, r;
  reg [31:0] entry;

  int disp [6];
  int unsup = 0, done0 = 0, bad_done0 = 0, cpu_dones = 0;
  initial for (int e = 0; e < 6; e++) disp[e] = 0;
  always @(posedge clk) if (rst_n) begin
    for (int e = 0; e < 6; e++) if (dut.eng_valid[e]) disp[e]++;
    if (dut.m_err_unsupported) unsup++;
    // every completion the scheduler sees from slot 0 must be the CPU's own,
    // with its tag -- a job must not retire before the core has halted
    if (dut.cpu_done) cpu_dones++;
    if (dut.eng_done[0]) begin
      done0++;
      if (!dut.cpu_done || dut.eng_done_tag[3:0] !== dut.cpu_done_tag) bad_done0++;
    end
  end
  int base [6];
  int base_unsup;
  task automatic mark(); for (int e = 0; e < 6; e++) base[e] = disp[e]; base_unsup = unsup; endtask
  function automatic int went();
    int w = -1;
    for (int e = 0; e < 6; e++) if (disp[e] != base[e]) w = (w == -1 && disp[e] == base[e] + 1) ? e : -2;
    return w;
  endfunction
  task automatic expect_engine(input string what, input int want_e);
    int w = went();
    if (w != want_e) begin errors++; $display("FAIL %s: went to %0d, expected %0d (-1 = nowhere)", what, w, want_e); end
    else if (want_e < 0) $display("%s: dispatched nowhere", what);
    else $display("%s: engine %0d", what, want_e);
  endtask

  function automatic logic [63:0] hdr(input logic [2:0] pol);
    return {4'd2, 2'd0, pol, 8'd1, 16'd7, 8'd0, 8'd0, 15'd0};
  endfunction
  task automatic submit(input logic [63:0] h, input logic [3:0] opc, input logic [2:0] dtype,
                        input int m, input int n, input int k, input int wait_cycles);
    logic [127:0] desc;
    ctl(4'd2, h[31:0]); ctl(4'd3, h[63:32]);
    desc = '0;
    desc[127:124] = opc; desc[123:121] = dtype;
    desc[116:101] = 16'(m); desc[100:85] = 16'(n); desc[84:69] = 16'(k);
    wr(7'h01, 16, desc); wr(7'h03, 1, 128'h01);
    repeat (wait_cycles) @(posedge clk);
  endtask
  task automatic load_cpu();
    ctl(4'd6, 32'd0);
    for (int w = 0; w < 16384; w++) ctl(4'd7, {img[4*w+3], img[4*w+2], img[4*w+1], img[4*w]});
  endtask
  task automatic check_cpu_regs(input string what);
    logic [31:0] lo, hi, st;
    int bad = 0;
    for (int i = 1; i < 32; i++) begin
      ctl(4'd10, i); ctl_read(4'd2, lo); ctl_read(4'd3, hi);
      if ({hi, lo} !== want[i]) begin bad++; if (bad < 4) $display("  %s x%0d: %016x, model %016x", what, i, {hi, lo}, want[i]); end
    end
    ctl_read(4'd4, st);
    if (bad) begin errors++; $display("FAIL %s: %0d registers differ from Sixfold's model", what, bad); end
    if (st[31:30] !== 2'd0 || st[29:0] !== want_tohost[29:0]) begin
      errors++; $display("FAIL %s: CPU status %0d TOHOST %0h, model TOHOST %0h", what, st[31:30], st[29:0], want_tohost);
    end
  endtask

  initial begin #2_000_000_000; $display("FAIL tb_sys_tile_cpu: watchdog"); $fatal(1); end

  initial begin
    if (!$value$plusargs("dir=%s", dir)) begin $display("FAIL: +dir= not given"); $fatal(1); end
    for (int a = 0; a < 65536; a++) img[a] = 8'h00;
    $readmemh({dir, "/prog.hex"}, img);
    $readmemh({dir, "/regs.txt"}, want);
    fd = $fopen({dir, "/info.txt"}, "r"); r = $fscanf(fd, "%h %d %h", want_tohost, want_cycles, entry); $fclose(fd);

    repeat (5) @(posedge clk); rst_n = 1;
    repeat (20) @(posedge clk);
    ctl(4'd4, {7'd0, 1'b1, 8'd1, 16'd7});            // own context 1, epoch 7
    load_cpu(); ctl(4'd8, entry);

    // 1. scalar work, AUTO: only the CPU can do it
    mark(); submit(hdr(3'd0), 4'd0, 3'd2, 64, 1, 1, 3000 + want_cycles);
    expect_engine("1 AUTO scalar", 0);
    check_cpu_regs("1 AUTO scalar");

    // 2. the GPU cannot run scalar code
    mark(); submit(hdr(3'd2), 4'd0, 3'd2, 64, 1, 1, 3000);
    expect_engine("2 policy GPU, scalar", -1);
    if (unsup != base_unsup + 1) begin errors++; $display("FAIL 2: not refused by the scheduler"); end

    // 3. forced to the CPU although the GPU would be cheaper: same answer again
    load_cpu();
    mark(); submit(hdr(3'd1), 4'd3, 3'd2, 32, 32, 64, 3000 + want_cycles);
    expect_engine("3 policy CPU, INT32 GEMM", 0);
    check_cpu_regs("3 policy CPU");

    // 4. CPU unhealthy: nothing eligible can run scalar code
    ctl(4'd5, 32'b11_1110);
    mark(); submit(hdr(3'd0), 4'd0, 3'd2, 64, 1, 1, 3000);
    expect_engine("4 CPU unhealthy, scalar", -1);
    if (unsup != base_unsup + 1) begin errors++; $display("FAIL 4: not refused by the scheduler"); end

    if (bad_done0) begin errors++; $display("FAIL: %0d slot-0 completions were not the CPU's own", bad_done0); end
    if (done0 != 2 || cpu_dones != 2) begin
      errors++; $display("FAIL: the scheduler saw %0d slot-0 completions, the CPU made %0d; expected 2 each", done0, cpu_dones);
    end
    if (errors) begin $display("FAIL tb_sys_tile_cpu: %0d errors", errors); $fatal(1); end
    $display("PASS tb_sys_tile_cpu: CPU, GPU and TPU slots; a real Sixfold program scheduled to the CPU gives the model's registers; scalar work kept off the GPU");
    $finish;
  end
endmodule
`default_nettype wire

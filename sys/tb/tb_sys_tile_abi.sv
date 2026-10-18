// =============================================================================
// tb_sys_tile_abi.sv -- ABI version 2 on the chip, end to end
// =============================================================================
// Six slots (GPU on 5, memory-fed array on 2), version-2 headers loaded over
// the memory port, descriptors written over SPI, as a host would. Each case
// checks WHERE the job went (or that it went nowhere) by watching every
// engine's dispatch strobe, and the refusal code the chip reports:
//
//   1  no context yet                      -> refused CONTEXT, dispatched nowhere
//   2  AUTO, INT32 32x32x64 GEMM           -> the GPU (cheapest eligible); its
//                                             bank equals Pixelstorm's model
//   3  same job, policy CPU                -> engine 0, although the GPU is cheaper
//   4  INT8 GEMM, policy GPU               -> the GPU cannot do INT8: refused by
//                                             the scheduler, dispatched nowhere
//                                             (no fallback to the array)
//   5  security mode FHE                   -> refused MODE, dispatched nowhere
//   6  epoch bumped, old epoch in header   -> refused CONTEXT
//   7  GPU marked unhealthy: AUTO          -> the next cheapest eligible engine;
//                                policy GPU -> refused NO_ENGINE
//   +dir=<vector dir>   07_matmul from tools/gpu_vectors.js
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_sys_tile_abi;
  localparam int HALF = 5;
  localparam int GDEPTH = 4096;
  localparam logic [3:0] E_MODE = 4'd3, E_CONTEXT = 4'd5, E_NO_ENGINE = 4'd7;

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

  hydra_sys_tile #(.NENG(6), .TPU_ENGINE(2), .GPU_ENGINE(1), .ABI_V2(1)) dut (
    .ui_in(ui), .uo_out(uo), .uio_in(8'h00), .uio_out(uio), .uio_oe(uio_oe),
    .ena(1'b1), .clk(clk), .rst_n(rst_n),
    .dbg_checksum(), .dbg_tiles(), .dbg_simd_checksum(), .dbg_simd_jobs(),
    .mem_we(mem_we), .mem_bank(mem_bank), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_raddr(mem_raddr), .mem_rdata(mem_rdata), .mem_refused());

  // ---- SPI host ---------------------------------------------------------------
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
  task automatic load(input logic [1:0] bank, input int addr, input logic [31:0] w);
    @(negedge clk);
    mem_we = 1; mem_bank = bank; mem_addr = 16'(addr); mem_wdata = w;
    @(negedge clk);
    mem_we = 0;
  endtask
  task automatic read_status(output logic [31:0] s);
    @(negedge clk); mem_raddr = 16'hC000; @(negedge clk); @(negedge clk); s = mem_rdata;
  endtask

  // ---- vectors ------------------------------------------------------------------
  string dir;
  logic [31:0] imem [1024];
  logic [31:0] cmem [16];
  logic [31:0] init [GDEPTH];
  logic [31:0] expect_m [GDEPTH];
  integer grid, block, nwords, fd, r;

  // ---- where every job went -------------------------------------------------------
  int disp [6];
  int unsup = 0;
  initial for (int e = 0; e < 6; e++) disp[e] = 0;
  always @(posedge clk) if (rst_n) begin
    for (int e = 0; e < 6; e++) if (dut.eng_valid[e]) disp[e]++;
    if (dut.m_err_unsupported) unsup++;
  end
  int base [6];
  int base_unsup;
  task automatic mark();
    for (int e = 0; e < 6; e++) base[e] = disp[e];
    base_unsup = unsup;
  endtask
  function automatic int went();         // -1 nowhere, else the one engine, -2 more than one
    int w = -1;
    for (int e = 0; e < 6; e++) if (disp[e] != base[e]) w = (w == -1 && disp[e] == base[e] + 1) ? e : -2;
    return w;
  endfunction

  // ---- header ---------------------------------------------------------------------
  function automatic logic [63:0] hdr(input logic [1:0] mode, input logic [2:0] pol,
                                      input logic [7:0] ctx, input logic [15:0] epoch);
    return {4'd2, mode, pol, ctx, epoch, 8'd0, 8'd0, 15'd0};
  endfunction
  task automatic submit(input logic [63:0] h, input logic [2:0] dtype, input int m, input int n, input int k);
    logic [127:0] desc;
    load(2'd3, 16'hC002, h[31:0]);
    load(2'd3, 16'hC003, h[63:32]);
    desc = '0;
    desc[127:124] = 4'd3; desc[123:121] = dtype;
    desc[116:101] = 16'(m); desc[100:85] = 16'(n); desc[84:69] = 16'(k);
    desc[42:35] = 8'h5A;                                   // tag
    wr(7'h01, 16, desc); wr(7'h03, 1, 128'h01);
    repeat (30000) @(posedge clk);
  endtask
  task automatic expect_engine(input string what, input int want);
    int w = went();
    if (w != want) begin errors++; $display("FAIL %s: went to %0d, expected %0d (-1 = nowhere)", what, w, want); end
    else if (want < 0) $display("%s: dispatched nowhere", what);
    else $display("%s: engine %0d", what, want);
  endtask
  task automatic expect_refusal(input string what, input logic [3:0] code, input logic [15:0] count);
    logic [31:0] s;
    read_status(s);
    if (s[3:0] !== code || s[31:16] !== count) begin
      errors++; $display("FAIL %s: refusal code %0d count %0d, expected %0d count %0d", what, s[3:0], s[31:16], code, count);
    end
  endtask

  initial begin #400_000_000; $display("FAIL tb_sys_tile_abi: watchdog"); $fatal(1); end

  logic [31:0] s;
  int gpu_bad;
  initial begin
    if (!$value$plusargs("dir=%s", dir)) begin $display("FAIL: +dir= not given"); $fatal(1); end
    for (int i = 0; i < 1024; i++) imem[i] = 32'd0;
    $readmemh({dir, "/imem.hex"}, imem);
    $readmemh({dir, "/cmem.hex"}, cmem);
    $readmemh({dir, "/init.hex"}, init);
    $readmemh({dir, "/expect.hex"}, expect_m);
    fd = $fopen({dir, "/job.txt"}, "r"); r = $fscanf(fd, "%d %d %d", grid, block, nwords); $fclose(fd);

    repeat (5) @(posedge clk); rst_n = 1;
    repeat (20) @(posedge clk);
    for (int i = 0; i < nwords; i++) load(2'd3, 16'h4000 | i, imem[i]);
    for (int i = 0; i < 16; i++)     load(2'd3, 16'h8000 | i, cmem[i]);
    for (int i = 0; i < GDEPTH; i++) load(2'd3, i, init[i]);
    load(2'd3, 16'hC000, 32'(grid)); load(2'd3, 16'hC001, 32'(block));

    // 1. no context owned yet
    mark(); submit(hdr(2'd0, 3'd0, 8'd1, 16'd7), 3'd2, 32, 32, 64);
    expect_engine("1 no context", -1); expect_refusal("1 no context", E_CONTEXT, 16'd1);

    // own context 1 at epoch 7
    load(2'd3, 16'hC004, {7'd0, 1'b1, 8'd1, 16'd7});

    // 2. AUTO -> the GPU, with Pixelstorm's result in the bank
    mark(); submit(hdr(2'd0, 3'd0, 8'd1, 16'd7), 3'd2, 32, 32, 64);
    expect_engine("2 AUTO INT32 GEMM", 5);
    gpu_bad = 0;
    for (int a = 0; a < GDEPTH; a++) if (dut.g_real_gpu.u_gpu.u_bank.mem[a] !== expect_m[a]) gpu_bad++;
    if (gpu_bad) begin errors++; $display("FAIL 2: %0d GPU bank words differ from Pixelstorm's model", gpu_bad); end

    // 3. same job forced to the CPU slot
    mark(); submit(hdr(2'd0, 3'd1, 8'd1, 16'd7), 3'd2, 32, 32, 64);
    expect_engine("3 policy CPU", 0);

    // 4. INT8 GEMM forced to the GPU: not capable, refused, no fallback
    mark(); submit(hdr(2'd0, 3'd2, 8'd1, 16'd7), 3'd0, 4, 4, 64);
    expect_engine("4 policy GPU, INT8", -1);
    if (unsup != base_unsup + 1) begin errors++; $display("FAIL 4: the scheduler did not refuse the job (%0d refusals)", unsup - base_unsup); end

    // 5. FHE
    mark(); submit(hdr(2'd1, 3'd0, 8'd1, 16'd7), 3'd2, 32, 32, 64);
    expect_engine("5 security mode FHE", -1); expect_refusal("5 FHE", E_MODE, 16'd2);

    // 6. epoch bumped: the old epoch is revoked
    load(2'd3, 16'hC004, {7'd0, 1'b1, 8'd1, 16'd8});
    mark(); submit(hdr(2'd0, 3'd0, 8'd1, 16'd7), 3'd2, 32, 32, 64);
    expect_engine("6 stale epoch", -1); expect_refusal("6 stale epoch", E_CONTEXT, 16'd3);

    // 7. the GPU marked unhealthy
    load(2'd3, 16'hC005, 32'b01_1111);
    mark(); submit(hdr(2'd0, 3'd0, 8'd1, 16'd8), 3'd2, 32, 32, 64);
    expect_engine("7a GPU unhealthy, AUTO", 1);              // the vector unit is next cheapest
    mark(); submit(hdr(2'd0, 3'd2, 8'd1, 16'd8), 3'd2, 32, 32, 64);
    expect_engine("7b GPU unhealthy, policy GPU", -1); expect_refusal("7b", E_NO_ENGINE, 16'd4);

    if (errors) begin $display("FAIL tb_sys_tile_abi: %0d errors", errors); $fatal(1); end
    $display("PASS tb_sys_tile_abi: 8 cases; eligibility before cost, forced engines honoured, refusals with no fallback");
    $finish;
  end
endmodule
`default_nettype wire

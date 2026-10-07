/*
 * hydra_engine_tpu_dma.sv -- the array, fed from real memory
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * hydra_engine_tpu with the pattern generator replaced by a scratchpad and
 * a streamer. The descriptor now carries the three bank addresses in its
 * reserved bits (see hydra_dma_gemm.sv), so software says WHERE the
 * operands are instead of the hardware inventing them.
 *
 * The banks are written from outside -- a testbench, or the board bridge --
 * through a simple load port. That port is deliberately separate from the
 * streamer's ports: a loader sharing the streamer's address path would make
 * every load a special case in the state machine it has to share.
 */
`default_nettype none
module hydra_engine_tpu_dma
  import tpu_pkg::*;
#(
  parameter int unsigned N     = N_PE,
  parameter int unsigned WD_W  = 128,
  parameter int unsigned TAGW  = 4,
  parameter int unsigned AW    = 10,
  parameter int unsigned DEPTH = 1024
) (
  input  wire              clk,
  input  wire              rst_n,

  // engine port
  input  wire              eng_valid,
  output logic             eng_ready,
  input  wire [WD_W-1:0]   eng_wd,
  input  wire [TAGW-1:0]   eng_tag,
  output logic             eng_done,
  output logic [TAGW-1:0]  eng_done_tag,

  // scratchpad load port: bank 0 = A, 1 = B, 2 = C
  input  wire              ld_we,
  input  wire [1:0]        ld_bank,
  input  wire [AW-1:0]     ld_addr,
  input  wire [31:0]       ld_data,

  // result readback, for a host or a bench
  input  wire [AW-1:0]     c_raddr,
  output logic [31:0]      c_rdata,

  output logic [15:0]      tiles_done,
  output tpu_status_e      last_status
);
  // ---- descriptor: dimensions and the three bank addresses ---------------
  wire [KW-1:0] wd_m = eng_wd[116:101];
  wire [KW-1:0] wd_k = eng_wd[84:69];
  wire [AW-1:0] base_a = eng_wd[3 +: AW];
  wire [AW-1:0] base_b = eng_wd[13 +: AW];
  wire [AW-1:0] base_c = eng_wd[23 +: AW];

  // The engine and the streamer must BOTH be free before a job is taken.
  // The engine's ready alone is not enough: the streamer can still be
  // draining the previous job's results for a cycle or two after the
  // engine reports idle.
  wire dma_busy;
  wire core_ready;
  assign eng_ready = core_ready && !dma_busy;
  wire accept = eng_valid && eng_ready;

  // ---- banks --------------------------------------------------------------
  wire [AW-1:0] dma_a_addr, dma_b_addr, dma_c_addr;
  wire [31:0]   a_rdata, b_rdata, c_wdata;
  wire          c_we;

  // The loader and the streamer take turns: loads only happen between jobs,
  // which the bench and the bridge both honour, and the engine is idle then.
  wire [AW-1:0] a_addr = (ld_we && ld_bank == 2'd0) ? ld_addr : dma_a_addr;
  wire [AW-1:0] b_addr = (ld_we && ld_bank == 2'd1) ? ld_addr : dma_b_addr;
  wire [AW-1:0] c_addr = (ld_we && ld_bank == 2'd2) ? ld_addr :
                         c_we                       ? dma_c_addr : c_raddr;

  hydra_spram #(.DW(32), .DEPTH(DEPTH), .AW(AW)) u_a (
    .clk(clk), .we(ld_we && ld_bank == 2'd0), .addr(a_addr),
    .wdata(ld_data), .rdata(a_rdata));

  hydra_spram #(.DW(32), .DEPTH(DEPTH), .AW(AW)) u_b (
    .clk(clk), .we(ld_we && ld_bank == 2'd1), .addr(b_addr),
    .wdata(ld_data), .rdata(b_rdata));

  hydra_spram #(.DW(32), .DEPTH(DEPTH), .AW(AW)) u_c (
    .clk(clk), .we(c_we || (ld_we && ld_bank == 2'd2)), .addr(c_addr),
    .wdata((ld_we && ld_bank == 2'd2) ? ld_data : c_wdata), .rdata(c_rdata));

  // ---- streamer -----------------------------------------------------------
  wire                 op_valid, op_ready;
  wire [31:0]          op_a_w, op_b_w;
  wire                 res_valid, res_last;
  wire signed [ACCW-1:0] res_data;

  hydra_dma_gemm #(.AW(AW), .DW(32), .CNTW(KW)) u_dma (
    .clk(clk), .rst_n(rst_n),
    .start(accept), .base_a(base_a), .base_b(base_b), .base_c(base_c),
    .k_slices(wd_k), .n_results(KW'(N*N)), .busy(dma_busy),
    .a_addr(dma_a_addr), .a_rdata(a_rdata),
    .b_addr(dma_b_addr), .b_rdata(b_rdata),
    .w_addr(), .w_rdata(32'h0), .op_w(),
    .c_addr(dma_c_addr), .c_we(c_we), .c_wdata(c_wdata),
    .op_valid(op_valid), .op_ready(op_ready), .op_a(op_a_w), .op_b(op_b_w),
    .res_valid(res_valid), .res_data(res_data));

  // A word is four lanes, lane 0 in the low byte. Lanes past the tile carry
  // whatever the loader put there, so the loader zeroes them -- the engine
  // has no idea which lanes are inside the tile and should not need to.
  localparam int unsigned AW_LANE = 8;
  logic signed [AW_LANE-1:0] op_a_lane [N];
  logic signed [AW_LANE-1:0] op_b_lane [N];
  always_comb begin
    for (int l = 0; l < N; l++) begin
      op_a_lane[l] = signed'(op_a_w[l*8 +: 8]);
      op_b_lane[l] = signed'(op_b_w[l*8 +: 8]);
    end
  end

  tpu_top #(.N(N), .WD_W(WD_W), .TAGW(TAGW)) u_tpu (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(accept), .eng_ready(core_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .op_ready(op_ready), .op_valid(op_valid),
    .op_a(op_a_lane), .op_b(op_b_lane),
    .res_valid(res_valid), .res_data(res_data), .res_last(res_last),
    .status(last_status));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        tiles_done <= '0;
    else if (eng_done) tiles_done <= tiles_done + 16'd1;
  end

  wire _unused = &{res_last, wd_m, 1'b0};
endmodule
`default_nettype wire

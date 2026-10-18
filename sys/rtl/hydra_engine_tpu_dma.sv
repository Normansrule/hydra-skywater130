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
  output logic             ld_refused,      // pulses: a load the engine owned the banks for

  // result readback, for a host or a bench
  input  wire [AW-1:0]     c_raddr,
  output logic [31:0]      c_rdata,

  output logic [15:0]      tiles_done,
  output logic [2:0]       job_status       // the core's four, or 4 = past a bank's end
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
  //
  // Audit R3 follow-up (2026-10-11): the streamer used to start for EVERY
  // accepted descriptor. One the core refuses -- a 5-row tile, say -- never
  // has its operands taken, so the streamer waited for ever and the engine
  // never became ready again: one bad descriptor from the host wedged the
  // array until reset. Now the core's own acceptance test is mirrored here
  // and the streamer starts only for a job the core will run. A job whose
  // operands or results would run past the end of a bank is refused before
  // anything is read or written (job_status = 4). The core's done is held
  // until the streamer has written every result, so done means "in memory".
  wire [KW-1:0] wd_n = eng_wd[100:85];
  wire core_will_run = (eng_wd[127:124] == 4'd3) && (eng_wd[123:121] == 3'd0) &&
                       (wd_m != '0) && (wd_n != '0) && (wd_k != '0) &&
                       (wd_m <= KW'(N)) && (wd_n <= KW'(N));
  wire in_range = ({1'b0, KW'(base_a)} + {1'b0, wd_k} <= (KW+1)'(DEPTH)) &&
                  ({1'b0, KW'(base_b)} + {1'b0, wd_k} <= (KW+1)'(DEPTH)) &&
                  ({1'b0, KW'(base_c)} + (KW+1)'(N*N) <= (KW+1)'(DEPTH));

  wire dma_busy;
  wire core_ready;
  logic done_pend_q, rej_pend_q;
  logic [TAGW-1:0] pend_tag_q;
  assign eng_ready = core_ready && !dma_busy && !done_pend_q && !rej_pend_q;
  wire accept  = eng_valid && eng_ready;
  wire refuse  = accept && core_will_run && !in_range;
  wire to_core = accept && !refuse;
  wire run_job = to_core && core_will_run;

  // ---- banks --------------------------------------------------------------
  wire [AW-1:0] dma_a_addr, dma_b_addr, dma_c_addr;
  wire [31:0]   a_rdata, b_rdata, c_wdata;
  wire          c_we;

  // Bank ownership (audit R8, 2026-10-11). This used to rely on the host
  // loading only between jobs; a load during a job took the bank port from
  // the streamer and overrode the engine's own result write. Now the engine
  // owns every bank from the cycle it accepts a job until it reports the
  // completion, and a host write in that window is refused and reported.
  // Host reads of C during a job return undefined data (the engine has the
  // port); they cannot change anything.
  wire host_owns = eng_ready && !accept;
  wire a_ld_we   = ld_we && host_owns && (ld_bank == 2'd0);
  wire b_ld_we   = ld_we && host_owns && (ld_bank == 2'd1);
  wire c_ld_we   = ld_we && host_owns && (ld_bank == 2'd2);
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ld_refused <= 1'b0;
    else        ld_refused <= ld_we && !host_owns;

  wire [AW-1:0] a_addr = a_ld_we ? ld_addr : dma_a_addr;
  wire [AW-1:0] b_addr = b_ld_we ? ld_addr : dma_b_addr;
  wire [AW-1:0] c_addr = c_ld_we ? ld_addr : c_we ? dma_c_addr : c_raddr;

  hydra_spram #(.DW(32), .DEPTH(DEPTH), .AW(AW)) u_a (
    .clk(clk), .we(a_ld_we), .addr(a_addr),
    .wdata(ld_data), .rdata(a_rdata));

  hydra_spram #(.DW(32), .DEPTH(DEPTH), .AW(AW)) u_b (
    .clk(clk), .we(b_ld_we), .addr(b_addr),
    .wdata(ld_data), .rdata(b_rdata));

  hydra_spram #(.DW(32), .DEPTH(DEPTH), .AW(AW)) u_c (
    .clk(clk), .we(c_we || c_ld_we), .addr(c_addr),
    .wdata(c_ld_we ? ld_data : c_wdata), .rdata(c_rdata));

  // ---- streamer -----------------------------------------------------------
  wire                 op_valid, op_ready;
  wire [31:0]          op_a_w, op_b_w;
  wire                 res_valid, res_last;
  wire signed [ACCW-1:0] res_data;

  hydra_dma_gemm #(.AW(AW), .DW(32), .CNTW(KW)) u_dma (
    .clk(clk), .rst_n(rst_n),
    .start(run_job), .base_a(base_a), .base_b(base_b), .base_c(base_c),
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

  wire            core_done;
  wire [TAGW-1:0] core_done_tag;
  tpu_status_e    core_status;
  tpu_top #(.N(N), .WD_W(WD_W), .TAGW(TAGW)) u_tpu (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(to_core), .eng_ready(core_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(core_done), .eng_done_tag(core_done_tag),
    .op_ready(op_ready), .op_valid(op_valid),
    .op_a(op_a_lane), .op_b(op_b_lane),
    .res_valid(res_valid), .res_data(res_data), .res_last(res_last),
    .status(core_status));

  wire commit_ok = done_pend_q && !dma_busy && !res_valid;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_pend_q <= 1'b0; rej_pend_q <= 1'b0; pend_tag_q <= '0;
      eng_done <= 1'b0; eng_done_tag <= '0; job_status <= 3'd0; tiles_done <= '0;
    end else begin
      eng_done <= 1'b0;
      if (core_done) begin
        done_pend_q <= 1'b1; pend_tag_q <= core_done_tag; job_status <= {1'b0, core_status};
      end
      if (refuse) begin
        rej_pend_q <= 1'b1; pend_tag_q <= eng_tag; job_status <= 3'd4;
      end
      if (commit_ok || rej_pend_q) begin
        eng_done <= 1'b1; eng_done_tag <= pend_tag_q;
        done_pend_q <= 1'b0; rej_pend_q <= 1'b0;
        tiles_done <= tiles_done + 16'd1;
      end
    end
  end

  wire _unused = &{res_last, 1'b0};
endmodule
`default_nettype wire

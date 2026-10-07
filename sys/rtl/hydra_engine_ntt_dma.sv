/*
 * hydra_engine_ntt_dma.sv -- the butterfly engine, fed from real memory
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * THREE OPERAND STREAMS
 * ===========================================================================
 * This is the engine the streamer's third port was built for. A butterfly
 * needs a, b AND the twiddle factor w, all for the same group, all in the
 * same cycle. The array and the vector unit need two streams and leave that
 * port unconnected; here all three are used, on one shared read pointer,
 * because every stream advances together by construction.
 *
 * ===========================================================================
 * BANK LAYOUT
 * ===========================================================================
 * A group is four residues of 14 bits. They are stored one per 16-bit slot,
 * so a group is 64 bits and a host word carries two lanes:
 *
 *   host word 2g+0 -> lanes 0,1 of group g   (lane 0 in bits [13:0])
 *   host word 2g+1 -> lanes 2,3 of group g
 *
 * Padding to 16 bits rather than packing 14 wastes two bits per lane and
 * makes the host's job arithmetic instead of bit-shuffling. At four lanes
 * that is one byte per group, which is not worth a loader that can cross
 * word boundaries.
 *
 * Residues are NOT range-checked on the way in. A value >= q entering the
 * butterfly produces a result that is wrong rather than merely unreduced,
 * and the engine cannot tell the difference. dma_ntt_model.py only generates
 * values below q, and tb_hydra_dma_ntt checks every result is a reduced
 * residue, which catches a bank loaded with garbage.
 */
`default_nettype none

module hydra_engine_ntt_dma
  import ntt_pkg::*;
#(
  parameter int unsigned N     = NLANE,
  parameter int unsigned WD_W  = 128,
  parameter int unsigned TAGW  = 4,
  parameter int unsigned AW    = 8,        // bank entries (groups)
  parameter int unsigned DEPTH = 256
) (
  input  wire              clk,
  input  wire              rst_n,

  input  wire              eng_valid,
  output logic             eng_ready,
  input  wire [WD_W-1:0]   eng_wd,
  input  wire [TAGW-1:0]   eng_tag,
  output logic             eng_done,
  output logic [TAGW-1:0]  eng_done_tag,

  // host load port: 32-bit words, bank 0 = A, 1 = B, 2 = W, 3 = results
  input  wire              ld_we,
  input  wire [1:0]        ld_bank,
  input  wire [AW:0]       ld_addr,        // one extra bit: two words per group
  input  wire [31:0]       ld_data,

  input  wire [AW+1:0]     c_raddr,
  output logic [31:0]      c_rdata,

  output logic [15:0]      jobs_done,
  output ntt_status_e      last_status
);
  localparam int unsigned SLOT = 16;        // one residue per 16-bit slot
  localparam int unsigned GW   = N * SLOT;  // 64 bits: one group

  // ---- descriptor ---------------------------------------------------------
  wire [3:0]      wd_opclass = eng_wd[127:124];
  wire [CNTW-1:0] wd_m       = eng_wd[116:101];
  wire [AW-1:0]   base_a     = eng_wd[3  +: AW];
  wire [AW-1:0]   base_b     = eng_wd[13 +: AW];
  wire [AW-1:0]   base_c     = eng_wd[23 +: AW];
  // The twiddles share the A base: a transform stage reads one twiddle per
  // pair group, and keeping a fourth base out of the reserved bits leaves
  // room there for whatever the direct memory access engine needs later.
  wire [CNTW-1:0] groups     = wd_m >> $clog2(N);

  wire dma_busy;
  wire core_ready;
  assign eng_ready = core_ready && !dma_busy;
  wire accept = eng_valid && eng_ready;

  // ---- banks: two host words make one group entry -------------------------
  wire [AW-1:0] ld_entry = ld_addr[AW:1];
  wire          ld_half  = ld_addr[0];

  wire [AW-1:0] dma_a_addr, dma_b_addr, dma_w_addr, dma_c_addr;
  wire [GW-1:0] a_rdata, b_rdata, w_rdata;
  wire [31:0]   c_wdata;
  wire          c_we;

  genvar h;
  generate
    for (h = 0; h < 2; h++) begin : g_half
      // Half h holds lanes 2h and 2h+1, written by host word 2g+h.
      wire sel = ld_we && (ld_half == h[0]);
      wire a_we = sel && (ld_bank == 2'd0);
      wire b_we = sel && (ld_bank == 2'd1);
      wire w_we = sel && (ld_bank == 2'd2);

      hydra_spram #(.DW(2*SLOT), .DEPTH(DEPTH), .AW(AW)) u_a (
        .clk(clk), .we(a_we), .addr(a_we ? ld_entry : dma_a_addr),
        .wdata(ld_data), .rdata(a_rdata[h*2*SLOT +: 2*SLOT]));

      hydra_spram #(.DW(2*SLOT), .DEPTH(DEPTH), .AW(AW)) u_b (
        .clk(clk), .we(b_we), .addr(b_we ? ld_entry : dma_b_addr),
        .wdata(ld_data), .rdata(b_rdata[h*2*SLOT +: 2*SLOT]));

      hydra_spram #(.DW(2*SLOT), .DEPTH(DEPTH), .AW(AW)) u_w (
        .clk(clk), .we(w_we), .addr(w_we ? ld_entry : dma_w_addr),
        .wdata(ld_data), .rdata(w_rdata[h*2*SLOT +: 2*SLOT]));
    end
  endgenerate

  // Results: a butterfly produces two residues, packed into one 32-bit word
  // (y0 low, y1 high) so the host reads one word per butterfly.
  wire          c_ld_we = ld_we && (ld_bank == 2'd3);
  wire [AW+1:0] c_addr  = c_ld_we ? ld_addr[AW+1:0] :
                          c_we    ? {2'b00, dma_c_addr} : c_raddr;

  hydra_spram #(.DW(32), .DEPTH(DEPTH*4), .AW(AW+2)) u_c (
    .clk(clk), .we(c_we || c_ld_we), .addr(c_addr),
    .wdata(c_ld_we ? ld_data : c_wdata), .rdata(c_rdata));

  // ---- streamer -----------------------------------------------------------
  wire          op_valid, op_ready;
  // The engine hands back N pairs at once and the result port carries one
  // word per cycle, so a group takes N cycles to leave. ntt_ctrl has no
  // back-pressure input -- it was written for an engine port that consumes
  // results as fast as they appear -- so the stall is applied here, at the
  // one place that knows about the serialiser. Without it the engine
  // swallows a group every cycle and three quarters of the results are
  // overwritten before they reach memory.
  wire          ser_stall;
  wire [GW-1:0] op_a, op_b, op_w;
  wire          res_valid;
  wire [N*QW-1:0] res_y0, res_y1;

  // One result word per butterfly: N per group.
  wire [CNTW-1:0] n_results = groups * CNTW'(N);

  hydra_dma_gemm #(.AW(AW), .DW(GW), .CNTW(CNTW)) u_dma (
    .clk(clk), .rst_n(rst_n),
    .start(accept), .base_a(base_a), .base_b(base_b), .base_c(base_c),
    .k_slices(groups), .n_results(n_results), .busy(dma_busy),
    .a_addr(dma_a_addr), .a_rdata(a_rdata),
    .b_addr(dma_b_addr), .b_rdata(b_rdata),
    .w_addr(dma_w_addr), .w_rdata(w_rdata), .op_w(op_w),
    .c_addr(dma_c_addr), .c_we(c_we), .c_wdata(c_wdata),
    .op_valid(op_valid), .op_ready(op_ready), .op_a(op_a), .op_b(op_b),
    .res_valid(res_serial), .res_data(res_word));

  // The butterfly engine hands back N pairs at once; the streamer writes one
  // word per cycle, so the pairs are serialised here.
  logic [$clog2(N+1)-1:0] ser_idx;
  logic                   ser_busy;
  logic [N*QW-1:0]        ser_y0, ser_y1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ser_idx <= '0; ser_busy <= 1'b0; ser_y0 <= '0; ser_y1 <= '0;
    end else if (res_valid && !ser_busy) begin
      ser_y0 <= res_y0; ser_y1 <= res_y1; ser_idx <= '0; ser_busy <= 1'b1;
    end else if (ser_busy) begin
      if (ser_idx == ($clog2(N+1))'(N - 1)) ser_busy <= 1'b0;
      else                                   ser_idx <= ser_idx + 1'b1;
    end
  end

  wire        res_serial = ser_busy;
  wire [31:0] res_word   = {2'b00, ser_y1[ser_idx*QW +: QW],
                            2'b00, ser_y0[ser_idx*QW +: QW]};

  wire eng_op_ready;
  assign ser_stall = ser_busy || res_valid;
  assign op_ready  = eng_op_ready && !ser_stall;

  // ---- the engine ----------------------------------------------------------
  // Lane residues are the low QW bits of each 16-bit slot.
  logic [N*QW-1:0] lane_a, lane_b, lane_w;
  always_comb begin
    for (int l = 0; l < N; l++) begin
      lane_a[l*QW +: QW] = op_a[l*SLOT +: QW];
      lane_b[l*QW +: QW] = op_b[l*SLOT +: QW];
      lane_w[l*QW +: QW] = op_w[l*SLOT +: QW];
    end
  end

  ntt_top #(.N(N), .WD_W(WD_W), .TAGW(TAGW)) u_ntt (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(accept), .eng_ready(core_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .op_ready(eng_op_ready), .op_valid(op_valid && !ser_stall),
    .op_a(lane_a), .op_b(lane_b), .op_w(lane_w),
    .res_valid(res_valid), .res_y0(res_y0), .res_y1(res_y1),
    .status(last_status));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        jobs_done <= '0;
    else if (eng_done) jobs_done <= jobs_done + 16'd1;
  end

  wire _unused = &{wd_opclass, 1'b0};
endmodule

`default_nettype wire

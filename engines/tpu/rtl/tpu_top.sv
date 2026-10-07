/*
 * tpu_top.sv -- the TPU as an engine the dispatcher can use
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT THIS IS
 * ===========================================================================
 * An N x N output-stationary INT8 systolic array wearing the engine port
 * mom_xbar drives (eng_valid / eng_ready / eng_wd / eng_tag / eng_done /
 * eng_done_tag). Drop it in where the latency model sits in hydra_sys_tile
 * and the dispatcher cannot tell the difference, except that the answers are
 * real.
 *
 * Composition, one file per job:
 *   tpu_feeder  skews operands so they meet at the right processing element
 *   tpu_array   the grid
 *   tpu_drain   serialises the results to a 32-bit stream
 *   tpu_ctrl    the only state machine
 *
 * ===========================================================================
 * SCOPE, STATED PLAINLY
 * ===========================================================================
 * This computes ONE TILE: M and N up to the array edge, K unbounded. A larger
 * matrix multiply is several descriptors, which is how the dispatcher already
 * works -- it schedules units of work, and a tile is a unit. Tiling a big
 * GEMM in hardware means an address generator and a partial-sum memory, and
 * that belongs in its own module rather than hidden inside this one.
 *
 * Operands arrive as K slices: slice k carries column k of A and row k of B.
 * That is what a DMA engine streaming from a scratchpad naturally produces.
 * ===========================================================================
 */
`default_nettype none

module tpu_top
  import tpu_pkg::*;
#(
  parameter int unsigned N     = N_PE,
  parameter int unsigned WD_W  = 128,
  parameter int unsigned TAGW  = 4
) (
  input  wire                    clk,
  input  wire                    rst_n,

  // ---- engine port, as mom_xbar drives it ---------------------------------
  input  wire                    eng_valid,
  output logic                   eng_ready,
  input  wire [WD_W-1:0]         eng_wd,
  input  wire [TAGW-1:0]         eng_tag,
  output logic                   eng_done,
  output logic [TAGW-1:0]        eng_done_tag,

  // ---- operand stream: one k-slice per handshake --------------------------
  output logic                   op_ready,
  input  wire                    op_valid,
  input  wire signed [AW-1:0]    op_a [N],      // a[i][k] for every row i
  input  wire signed [AW-1:0]    op_b [N],      // b[k][j] for every column j

  // ---- result stream: row-major, one element per cycle --------------------
  output logic                   res_valid,
  output logic signed [ACCW-1:0] res_data,
  output logic                   res_last,

  // ---- why a job was refused, valid with eng_done -------------------------
  output tpu_status_e            status
);
  // ---------------------------------------------------------------------------
  // Descriptor decode. Field positions come from mom_pkg's work_desc_t; they
  // are restated as constants rather than importing the package so the engine
  // can be simulated and synthesised on its own.
  //   [127:124] op_class   3 = GEMM
  //   [123:121] dtype      0 = INT8
  //   [116:101] dim_m   [100:85] dim_n   [84:69] dim_k
  // ---------------------------------------------------------------------------
  localparam logic [3:0] OPC_GEMM_C = 4'd3;
  localparam logic [2:0] DT_INT8_C  = 3'd0;

  wire [3:0]    wd_opclass = eng_wd[127:124];
  wire [2:0]    wd_dtype   = eng_wd[123:121];
  wire [KW-1:0] wd_m       = eng_wd[116:101];
  wire [KW-1:0] wd_n       = eng_wd[100:85];
  wire [KW-1:0] wd_k       = eng_wd[84:69];

  logic [TAGW-1:0] tag_q;
  wire             ctrl_busy, ctrl_done;

  // The tag is captured on acceptance. The descriptor is NOT: the controller
  // latches the three dimensions it needs and nothing else stays live, so a
  // caller changing eng_wd mid-job cannot alter a running tile.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                          tag_q <= '0;
    else if (eng_valid && eng_ready)     tag_q <= eng_tag;
  end

  wire                   arr_clr, arr_en, arr_shift, feed_flush, feed_valid;
  wire                   row_valid, row_last, drain_busy;
  wire signed [AW-1:0]   a_skew [N];
  wire signed [AW-1:0]   b_skew [N];
  wire signed [ACCW-1:0] acc_south [N];

  tpu_ctrl #(.N(N)) u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .start(eng_valid && eng_ready),
    .dim_m(wd_m), .dim_n(wd_n), .dim_k(wd_k),
    .opclass_ok(wd_opclass == OPC_GEMM_C),
    .dtype_ok(wd_dtype == DT_INT8_C),
    .op_ready(op_ready), .op_valid(op_valid),
    .arr_clr(arr_clr), .arr_en(arr_en), .feed_valid(feed_valid),
    .arr_shift(arr_shift),
    .feed_flush(feed_flush),
    .row_valid(row_valid), .row_last(row_last), .drain_busy(drain_busy),
    .done(ctrl_done), .status(status), .busy(ctrl_busy));

  // Row order. Accumulators shift DOWNWARDS, so the bottom physical row
  // leaves first. Feeding logical row i into physical row N-1-i makes the
  // result stream come out row-major, which is what software expects and
  // what the model checks. The skew still matches, because the delay a lane
  // receives depends on the PHYSICAL row it drives, and that is what the
  // feeder indexes.
  logic signed [AW-1:0] a_rev [N];
  always_comb begin
    for (int i = 0; i < N; i++) a_rev[i] = op_a[N-1-i];
  end

  tpu_feeder #(.N(N)) u_feed (
    .clk(clk), .rst_n(rst_n), .flush(feed_flush),
    .step(arr_en), .in_valid(feed_valid), .a_slice(a_rev), .b_slice(op_b),
    .a_skew(a_skew), .b_skew(b_skew));

  tpu_array #(.N(N)) u_array (
    .clk(clk), .rst_n(rst_n), .en(arr_en), .clr(arr_clr), .shift_en(arr_shift),
    .a_west(a_skew), .b_north(b_skew), .acc_south(acc_south));

  logic [N*ACCW-1:0] south_packed;
  always_comb begin
    for (int i = 0; i < N; i++) south_packed[i*ACCW +: ACCW] = acc_south[i];
  end

  tpu_drain #(.N(N)) u_drain (
    .clk(clk), .rst_n(rst_n),
    .row_valid(row_valid), .row(south_packed), .row_last(row_last),
    .res_valid(res_valid), .res_data(res_data), .res_last(res_last),
    .busy(drain_busy));

  assign eng_ready    = !ctrl_busy;
  assign eng_done     = ctrl_done;
  assign eng_done_tag = tag_q;

endmodule

`default_nettype wire

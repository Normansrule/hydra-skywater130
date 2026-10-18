/*
 * hydra_engine_ntt_dma.sv -- the butterfly engine, fed from real memory
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * THREE OPERAND STREAMS
 * ===========================================================================
 * A butterfly needs a, b AND the twiddle factor w, all for the same group,
 * all in the same cycle. The streamer's third port carries w, on the one
 * shared read pointer, because every stream advances together.
 *
 * ===========================================================================
 * MEMORY FORMAT v1 (2026-10-11, audit R2/R3)
 * ===========================================================================
 * One residue per 32-bit host word, at every modulus. The first format put
 * residues in 16-bit slots, two per word: right only at q = 12289 (14 bits).
 * At q = 3329 (12 bits) the upper result landed two bits low; at
 * q = 8380417 (23 bits) a residue did not fit its slot at all. The end-to-end
 * test only ever ran at 12289. A 32-bit slot fits every modulus the engine
 * supports (QW <= 23) with nothing derived per width but the residue check.
 *
 * Units, all explicit:
 *   group          NLANE = 4 butterflies, side by side
 *   descriptor     base_a, base_b, base_c are GROUP indices (wd[3 +: AW],
 *                  wd[13 +: AW], wd[23 +: AW]); twiddles share base_a
 *   A, B, W banks  host word  group*4 + lane       one residue, bits [QW-1:0]
 *   C bank         host word  group*8 + 2*lane + 0  y0 of that butterfly
 *                             group*8 + 2*lane + 1  y1
 *   load / read    ld_addr and c_raddr are HOST WORD addresses
 *
 * Checked at this boundary, so the arithmetic never sees them:
 *   * a residue >= q, or any bit above QW, is refused: not written, and
 *     ld_refused pulses (the butterfly cannot tell an unreduced input from a
 *     reduced one, so the result would be silently wrong);
 *   * a load address past a bank's end is refused the same way;
 *   * a load while the engine owns the banks (from acceptance until the
 *     completion is reported) is refused the same way (audit R8);
 *   * a job whose operands or results would run past the end of a bank is
 *     refused before it starts: no operand is read, no result written, the
 *     tag completes with job_status = JS_BAD_RANGE, and the engine is free
 *     for the next job.
 *
 * ===========================================================================
 * DONE MEANS THE RESULTS ARE IN MEMORY
 * ===========================================================================
 * The butterfly core finishes while the last group's eight words are still
 * being serialised into the C bank. Its done is held here until the streamer
 * reports every result written (hydra_dma_gemm proves it stays busy until
 * then) and the serialiser is empty. Only then does the tag complete, so a
 * host that reads the results the cycle after completion reads final values.
 */
`default_nettype none

module hydra_engine_ntt_dma
  import ntt_pkg::*;
#(
  parameter int unsigned N     = NLANE,
  parameter int unsigned WD_W  = 128,
  parameter int unsigned TAGW  = 4,
  parameter int unsigned AW    = 8,        // group index width
  parameter int unsigned DEPTH = 256       // groups per bank
) (
  input  wire              clk,
  input  wire              rst_n,

  input  wire              eng_valid,
  output logic             eng_ready,
  input  wire [WD_W-1:0]   eng_wd,
  input  wire [TAGW-1:0]   eng_tag,
  output logic             eng_done,
  output logic [TAGW-1:0]  eng_done_tag,

  // host load port: bank 0 = A, 1 = B, 2 = W, 3 = C (results)
  input  wire              ld_we,
  input  wire [1:0]        ld_bank,
  input  wire [AW+$clog2(2*N)-1:0] ld_addr,   // host word address
  input  wire [31:0]       ld_data,
  output logic             ld_refused,      // pulses: a load was not written

  input  wire [AW+$clog2(2*N)-1:0] c_raddr,   // host word address in C
  output logic [31:0]      c_rdata,

  output logic [15:0]      jobs_done,
  output logic [2:0]       job_status       // see JS_* below
);
  localparam int unsigned SLOT = 32;                 // one residue per host word
  localparam int unsigned LW   = $clog2(N);          // lane select bits
  localparam int unsigned RPG  = 2 * N;              // result words per group
  localparam int unsigned RW   = $clog2(RPG);
  localparam int unsigned CAW  = AW + RW;            // C bank, in host words
  localparam int unsigned GW   = N * SLOT;           // one operand group

  // job_status: the core's four, plus the range refusal made here
  localparam logic [2:0] JS_OK = 3'd0, JS_BAD_OPCLASS = 3'd1, JS_BAD_DTYPE = 3'd2,
                         JS_BAD_DIMS = 3'd3, JS_BAD_RANGE = 3'd4;

  // The descriptor's base fields are ten bits.
  initial if (AW > 10) $error("hydra_engine_ntt_dma: AW %0d exceeds the 10-bit base fields", AW);

  // ---- descriptor ---------------------------------------------------------
  wire [CNTW-1:0] wd_m    = eng_wd[116:101];
  wire [AW-1:0]   base_a  = eng_wd[3  +: AW];
  wire [AW-1:0]   base_b  = eng_wd[13 +: AW];
  wire [AW-1:0]   base_c  = eng_wd[23 +: AW];
  wire [CNTW-1:0] groups  = wd_m >> LW;
  // The core's own acceptance test (ntt_top / ntt_ctrl), mirrored so the
  // streamer starts only for a job the core will run. A job the core
  // refuses -- wrong class, wrong type, a partial group -- goes to the core
  // alone, which reports why; started anyway, the streamer would wait for
  // the core to take operands forever.
  wire core_will_run = (eng_wd[127:124] == 4'd6) && (eng_wd[123:121] == 3'd5) &&
                       (wd_m[LW-1:0] == '0) && (wd_m != '0);

  // Every bank access of the job stays inside its bank. Widened by one bit
  // so the sum cannot wrap.
  function automatic logic fits(input logic [AW-1:0] base, input logic [CNTW-1:0] n);
    return ({1'b0, CNTW'(base)} + {1'b0, n}) <= (CNTW+1)'(DEPTH);
  endfunction
  wire in_range = fits(base_a, groups) && fits(base_b, groups) && fits(base_c, groups);

  // ---- who owns the engine port ---------------------------------------------
  wire dma_busy, core_ready;
  logic ser_busy;
  logic done_pend_q, rej_pend_q;            // a completion waiting to be reported
  logic [TAGW-1:0] pend_tag_q;
  assign eng_ready = core_ready && !dma_busy && !ser_busy && !done_pend_q && !rej_pend_q;
  wire accept  = eng_valid && eng_ready;
  wire refuse   = accept && core_will_run && !in_range;  // neither starts
  wire to_core  = accept && !refuse;                       // the core decides
  wire run_job  = to_core && core_will_run;                // and the streamer runs

  // ---- operand banks: one 32-bit lane memory per lane -----------------------
  wire [AW-1:0] ld_entry = ld_addr[LW +: AW];
  wire [LW-1:0] ld_lane  = ld_addr[LW-1:0];
  wire          ld_hi_ok = (ld_addr >> (AW + LW)) == '0;   // inside A/B/W
  wire          res_ok   = (ld_data >> QW) == '0 && ld_data[QW-1:0] < QW'(Q);
  wire          op_ld_ok = ld_hi_ok && (32'(ld_entry) < DEPTH) && res_ok;
  // Bank ownership (audit R8, 2026-10-11): from acceptance until the
  // completion is reported the engine owns every bank. A host write in that
  // window used to take the port from the streamer and override the
  // serialiser's result writes; now it is refused and reported like any
  // other bad load.
  wire          host_owns = eng_ready && !accept;

  wire [AW-1:0] dma_a_addr, dma_b_addr, dma_w_addr;
  wire [CAW-1:0] dma_c_addr;
  wire [GW-1:0] a_rdata, b_rdata, w_rdata;
  wire [31:0]   c_wdata;
  wire          c_we;

  genvar l;
  generate
    for (l = 0; l < N; l++) begin : g_lane
      wire sel  = ld_we && host_owns && op_ld_ok && (ld_lane == LW'(l));
      wire a_we = sel && (ld_bank == 2'd0);
      wire b_we = sel && (ld_bank == 2'd1);
      wire w_we = sel && (ld_bank == 2'd2);
      hydra_spram #(.DW(SLOT), .DEPTH(DEPTH), .AW(AW)) u_a (
        .clk(clk), .we(a_we), .addr(a_we ? ld_entry : dma_a_addr),
        .wdata(ld_data), .rdata(a_rdata[l*SLOT +: SLOT]));
      hydra_spram #(.DW(SLOT), .DEPTH(DEPTH), .AW(AW)) u_b (
        .clk(clk), .we(b_we), .addr(b_we ? ld_entry : dma_b_addr),
        .wdata(ld_data), .rdata(b_rdata[l*SLOT +: SLOT]));
      hydra_spram #(.DW(SLOT), .DEPTH(DEPTH), .AW(AW)) u_w (
        .clk(clk), .we(w_we), .addr(w_we ? ld_entry : dma_w_addr),
        .wdata(ld_data), .rdata(w_rdata[l*SLOT +: SLOT]));
    end
  endgenerate

  // ---- result bank, in host words --------------------------------------------
  // The host may preload C (a known pattern, to see what a job did not
  // write); that is any word, not a residue, so only the address is checked.
  wire c_ld_ok = 32'(ld_addr) < DEPTH * RPG;
  wire c_ld_we = ld_we && host_owns && (ld_bank == 2'd3) && c_ld_ok;
  wire [CAW-1:0] c_addr = c_ld_we ? CAW'(ld_addr) : c_we ? dma_c_addr : CAW'(c_raddr);
  hydra_spram #(.DW(32), .DEPTH(DEPTH * RPG), .AW(CAW)) u_c (
    .clk(clk), .we(c_we || c_ld_we), .addr(c_addr),
    .wdata(c_ld_we ? ld_data : c_wdata), .rdata(c_rdata));

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ld_refused <= 1'b0;
    else        ld_refused <= ld_we && (!host_owns || ((ld_bank == 2'd3) ? !c_ld_ok : !op_ld_ok));

  // ---- streamer --------------------------------------------------------------
  wire            op_valid, op_ready, ser_stall, res_valid;
  wire [GW-1:0]   op_a, op_b, op_w;
  wire [N*QW-1:0] res_y0, res_y1;
  wire [CNTW-1:0] n_results = groups * CNTW'(RPG);

  hydra_dma_gemm #(.AW(AW), .CAW(CAW), .DW(GW), .CNTW(CNTW)) u_dma (
    .clk(clk), .rst_n(rst_n),
    .start(run_job), .base_a(base_a), .base_b(base_b),
    .base_c(CAW'({base_c, {RW{1'b0}}})),          // group index -> host word
    .k_slices(groups), .n_results(n_results), .busy(dma_busy),
    .a_addr(dma_a_addr), .a_rdata(a_rdata),
    .b_addr(dma_b_addr), .b_rdata(b_rdata),
    .w_addr(dma_w_addr), .w_rdata(w_rdata), .op_w(op_w),
    .c_addr(dma_c_addr), .c_we(c_we), .c_wdata(c_wdata),
    .op_valid(op_valid), .op_ready(op_ready), .op_a(op_a), .op_b(op_b),
    .res_valid(ser_busy), .res_data(res_word));

  // ---- serialiser: 4 butterflies -> 8 words, y0 then y1 per lane --------------
  logic [RW-1:0]   ser_idx;
  logic [N*QW-1:0] ser_y0, ser_y1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ser_idx <= '0; ser_busy <= 1'b0; ser_y0 <= '0; ser_y1 <= '0;
    end else if (res_valid && !ser_busy) begin
      ser_y0 <= res_y0; ser_y1 <= res_y1; ser_idx <= '0; ser_busy <= 1'b1;
    end else if (ser_busy) begin
      if (ser_idx == RW'(RPG - 1)) ser_busy <= 1'b0;
      ser_idx <= ser_idx + 1'b1;
    end
  end
  wire [LW-1:0] ser_lane = ser_idx[RW-1:1];
  wire [31:0]   res_word = ser_idx[0] ? 32'(ser_y1[ser_lane*QW +: QW])
                                      : 32'(ser_y0[ser_lane*QW +: QW]);

  wire eng_op_ready;
  assign ser_stall = ser_busy || res_valid;
  assign op_ready  = eng_op_ready && !ser_stall;

  // ---- the engine --------------------------------------------------------------
  logic [N*QW-1:0] lane_a, lane_b, lane_w;
  always_comb
    for (int k = 0; k < N; k++) begin
      lane_a[k*QW +: QW] = op_a[k*SLOT +: QW];
      lane_b[k*QW +: QW] = op_b[k*SLOT +: QW];
      lane_w[k*QW +: QW] = op_w[k*SLOT +: QW];
    end

  wire             core_done;
  wire [TAGW-1:0]  core_done_tag;
  ntt_status_e     core_status;
  ntt_top #(.N(N), .WD_W(WD_W), .TAGW(TAGW)) u_ntt (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(to_core), .eng_ready(core_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(core_done), .eng_done_tag(core_done_tag),
    .op_ready(eng_op_ready), .op_valid(op_valid && !ser_stall),
    .op_a(lane_a), .op_b(lane_b), .op_w(lane_w),
    .res_valid(res_valid), .res_y0(res_y0), .res_y1(res_y1),
    .status(core_status));

  // ---- completion: after the last result word is in the C bank -----------------
  wire commit_ok = done_pend_q && !dma_busy && !ser_busy && !res_valid;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_pend_q <= 1'b0; rej_pend_q <= 1'b0; pend_tag_q <= '0;
      eng_done <= 1'b0; eng_done_tag <= '0; job_status <= JS_OK; jobs_done <= '0;
    end else begin
      eng_done <= 1'b0;
      if (core_done) begin
        done_pend_q <= 1'b1; pend_tag_q <= core_done_tag;
        job_status  <= {1'b0, core_status};
      end
      if (refuse) begin
        rej_pend_q <= 1'b1; pend_tag_q <= eng_tag; job_status <= JS_BAD_RANGE;
      end
      if (commit_ok || rej_pend_q) begin
        eng_done <= 1'b1; eng_done_tag <= pend_tag_q;
        done_pend_q <= 1'b0; rej_pend_q <= 1'b0;
        jobs_done <= jobs_done + 16'd1;
      end
    end
  end

`ifdef FORMAL
  // The completion is never reported while a result is still on its way.
  always_ff @(posedge clk) if (rst_n && eng_done && !$past(rej_pend_q))
    assert (!$past(dma_busy) && !$past(ser_busy));
`endif
endmodule

`default_nettype wire

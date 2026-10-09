/*
 * mom_features.sv
 *
 * HYDRA-130 - MOM pipeline stage 1: feature extraction
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS STAGE COMPUTES
 * ---------------------------------------------------------------------------
 * Given a work descriptor, produce three numbers that the cost model needs:
 *
 *   W       work volume in operations
 *   Q       operand traffic in bytes (taken straight from the descriptor)
 *   log2(I) arithmetic intensity, as a base-2 logarithm
 *
 * Arithmetic intensity is the roofline model's x-axis (Williams, Waterman, &
 * Patterson, 2009):
 *
 *     I = W / Q            operations per byte moved
 *
 * A design that computed I directly would need a 32-bit divider, which is
 * hundreds of gates and several cycles. We do not need I itself. We need it
 * only to evaluate
 *
 *     P_att = min(P_peak, I * BW)
 *
 * and both P_peak and BW are stored as base-2 logarithms in the parameter ROM.
 * So working in the log domain turns that multiply into an add:
 *
 *     log2(P_att) = min(log2(P_peak), log2(I) + log2(BW))
 *
 * and log2(I) = log2(W) - log2(Q) is a subtraction of two priority-encoder
 * outputs. The whole thing costs about 40 gates instead of a divider.
 *
 * The cost of working in logs is precision: we lose the mantissa, so P_att is
 * accurate to within a factor of two. That would matter if the model were the
 * final word. It is not. mom_calibrate.sv corrects the residual error from
 * measured completion times, which is the entire reason the calibration loop
 * exists.
 *
 * ---------------------------------------------------------------------------
 * WORK VOLUME FORMULAS
 * ---------------------------------------------------------------------------
 * By operation class, from PROJECT_PLAN.md section 5.3:
 *
 *   OPC_SCALAR, OPC_ELEMENT, OPC_REDUCE   W = M
 *   OPC_GEMM                              W = 2 * M * N * K
 *   OPC_CONV2D                            W = 2 * M * N * K   (K packs Kh*Kw*Cin)
 *   OPC_FFT                               W = 5 * N * log2(N)
 *   OPC_NTT                               W = (N/2) * log2(N) * CBF
 *   OPC_CIPHER                            W = bytes * CPB
 *   OPC_HASH                              W = ceil(bytes/64) * CPBLK
 *
 * We compute log2(W) rather than W, so the products above become sums of
 * logarithms and the tree collapses to a few adders.
 *
 * CBF is the cycles-per-butterfly constant. A Cooley-Tukey butterfly is one
 * modular multiply plus a modular add and a modular subtract. With Montgomery
 * reduction that is roughly 4 equivalent operations, so CBF = 4.
 * ---------------------------------------------------------------------------
 */

`default_nettype none

module mom_features
  import mom_pkg::*;
(
  input  wire                     clk,
  input  wire                     rst_n,

  // ---- input: one work descriptor per handshake ----------------------------
  input  wire                     in_valid,
  output wire                     in_ready,
  input  wire  work_desc_t        in_wd,

  // ---- output: extracted features, registered ------------------------------
  output logic                    out_valid,
  input  wire                     out_ready,
  output work_desc_t              out_wd,        // passed through unchanged
  output logic [7:0]              out_log2_w,    // log2 of work volume
  output logic [7:0]              out_log2_q,    // log2 of operand bytes
  output logic signed [8:0]       out_log2_i     // log2 of arithmetic intensity
);

  // ---------------------------------------------------------------------------
  // Skid-free single-stage handshake.
  //
  // We accept a new descriptor whenever the output register is empty or is
  // being drained this cycle. One descriptor in flight, which is all we need:
  // the FIFO ahead of us absorbs bursts, and dispatch decisions are not on any
  // critical loop.
  // ---------------------------------------------------------------------------
  assign in_ready = (!out_valid) || out_ready;

  wire accept = in_valid && in_ready;

  // ---------------------------------------------------------------------------
  // log2 helper: position of the most significant set bit.
  //
  // Synthesizes to a priority encoder. Returns 0 for an input of 0, which is
  // the right behavior here because a zero-length problem should score as
  // trivially cheap on every engine and the selector will fall through to the
  // CPU by tie-break order.
  // ---------------------------------------------------------------------------
  // The MSB-index helper now lives in mom_pkg::flog2. It was moved there
  // after the local version was found to return garbage under Icarus: a
  // variable bit-select inside a function called from always_comb is not
  // supported and silently includes every bit. See mom_pkg.sv for the
  // binary-search replacement and the full explanation.

  // ---------------------------------------------------------------------------
  // Combinational feature extraction.
  //
  // Every term below is a logarithm, so multiplication becomes addition. The
  // constants:
  //
  //   +1  multiply by 2   (the two ops of a fused multiply-accumulate)
  //   +2  multiply by 4   (CBF, cycles per NTT butterfly)
  //   log2(5) ~= 2.32, rounded to 2, for the FFT constant. The 16% error this
  //             introduces is far inside what the calibration loop absorbs.
  // ---------------------------------------------------------------------------
  logic [7:0] lg_m, lg_n, lg_k, lg_q;
  logic [7:0] lg_w_c;

  always_comb begin
    lg_m = flog2({16'd0, in_wd.dim_m});
    lg_n = flog2({16'd0, in_wd.dim_n});
    lg_k = flog2({16'd0, in_wd.dim_k});
    lg_q = flog2({8'd0,  in_wd.bytes});

    unique case (in_wd.op_class)
      // -- linear in M ------------------------------------------------------
      OPC_SCALAR,
      OPC_ELEMENT,
      OPC_REDUCE:  lg_w_c = lg_m;

      // -- W = 2*M*N*K ------------------------------------------------------
      OPC_GEMM,
      OPC_CONV2D:  lg_w_c = lg_m + lg_n + lg_k + 8'd1;

      // -- W = 5*N*log2(N), log2(5) rounded to 2 ----------------------------
      //    log2(W) = 2 + log2(N) + log2(log2(N))
      OPC_FFT:     lg_w_c = 8'd2 + lg_n + flog2({24'd0, lg_n});

      // -- W = (N/2)*log2(N)*CBF, CBF=4 so -1 for /2 and +2 for *4 ----------
      OPC_NTT:     lg_w_c = lg_n + flog2({24'd0, lg_n}) + 8'd1;

      // -- cipher and hash are proportional to byte count --------------------
      //    AES-GCM runs about 1 byte/cycle, SHA-2 about 1 byte per 1.2 cycles.
      //    Both round to log2(Q) at this precision.
      OPC_CIPHER,
      OPC_HASH:    lg_w_c = lg_q;

      default:     lg_w_c = lg_m;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Arithmetic intensity in the log domain.
  //
  //   log2(I) = log2(W) - log2(Q)
  //
  // Signed, because a memory-bound kernel has I < 1 and therefore log2(I) < 0.
  // That is the interesting half of the roofline: it is exactly the regime
  // where the TPU loses to the CPU despite having 256 multipliers, because it
  // spends all its time waiting on operands.
  // ---------------------------------------------------------------------------
  wire signed [8:0] lg_i_c = $signed({1'b0, lg_w_c}) - $signed({1'b0, lg_q});

  // ---------------------------------------------------------------------------
  // Output register
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid  <= 1'b0;
      out_wd     <= '0;
      out_log2_w <= 8'd0;
      out_log2_q <= 8'd0;
      out_log2_i <= 9'sd0;
    end else begin
      if (accept) begin
        out_valid  <= 1'b1;
        out_wd     <= in_wd;
        out_log2_w <= lg_w_c;
        out_log2_q <= lg_q;
        out_log2_i <= lg_i_c;
      end else if (out_ready) begin
        out_valid  <= 1'b0;
      end
    end
  end

`ifdef FORMAL
  // A descriptor accepted this cycle must appear at the output next cycle.
  // Checked with SymbiYosys in tb/formal/.
  always @(posedge clk) begin
    if (rst_n && $past(rst_n) && $past(accept))
      assert (out_valid && out_wd == $past(in_wd));
  end
`endif

endmodule

`default_nettype wire

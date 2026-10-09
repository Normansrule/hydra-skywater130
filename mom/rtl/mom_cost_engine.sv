/*
 * mom_cost_engine.sv
 *
 * HYDRA-130 - MOM pipeline stage 2: per-engine roofline cost model
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * ONE INSTANCE PER ENGINE
 * ===========================================================================
 * Five copies of this module run in parallel, one per engine, each fed the
 * same extracted features and its own parameter row. Each produces a scalar
 * cost. mom_select.sv takes the argmin. Parallel rather than sequential
 * because five copies of a shifter and two adders is about 3,000 GE total,
 * and a sequential version would put five cycles on the dispatch path.
 *
 * ===========================================================================
 * THE MODEL
 * ===========================================================================
 * Roofline (Williams, Waterman, & Patterson, 2009): attainable performance is
 * the lesser of what the engine can compute and what memory can feed it.
 *
 *     P_att = min( P_peak, I * BW )                                    ... (1)
 *
 * Both P_peak and BW arrive as base-2 logarithms from the parameter ROM, and
 * mom_features.sv already produced log2(I). So equation (1) becomes a min of
 * two small integers, with the product replaced by a sum:
 *
 *     log2(P_att) = min( p_peak_log2, log2_i + bw_log2 )               ... (2)
 *
 * No multiplier, no divider. A 4-bit adder and a 4-bit comparator.
 *
 * Compute cycles then follow from W / P_att, which in the log domain is:
 *
 *     log2(T_compute) = log2_w - log2(P_att)                           ... (3)
 *
 * We need actual cycles from here, because the remaining terms (setup, DMA,
 * queue depth) are linear and cannot stay in logs. So one barrel shift:
 *
 *     T_compute = 1 << log2(T_compute)                                 ... (4)
 *
 * Total predicted cycles:
 *
 *     T_hat = T_compute + t_setup + (Q >> bw_dma_log2) + queue_depth   ... (5)
 *                          ^^^^^^^   ^^^^^^^^^^^^^^^^^   ^^^^^^^^^^^
 *                          fixed     operand movement    contention
 *
 * Then the online calibration factor, Q1.7, from mom_calibrate.sv:
 *
 *     T_cal = (k_e * T_hat) >> 7                                       ... (6)
 *
 * Energy, in units of 0.25 pJ:
 *
 *     E_hat = W * eps_op + Q * eps_mem                                 ... (7)
 *
 * And the objective the selector minimizes:
 *
 *     J = T_cal + (lambda * E_hat) >> e_shift                          ... (8)
 *
 * where lambda comes from the descriptor's power hint and e_shift is a CSR
 * that normalizes energy units into cycle units for the platform.
 *
 * ===========================================================================
 * ON PRECISION
 * ===========================================================================
 * Working in logs throws away the mantissa, so T_compute from equation (4) is
 * accurate only to within a factor of two. That would be disqualifying if the
 * model were the last word.
 *
 * It is not. mom_calibrate.sv observes actual completion times and drives k_e
 * to whatever value makes the prediction match reality, including absorbing
 * this systematic log-domain error. The model needs to get the SHAPE right
 * (memory-bound versus compute-bound, which engine scales with which
 * dimension); the calibration loop gets the SCALE right.
 *
 * That division of labour is the whole design idea. It is why this fits in
 * 15,000 gates instead of 150,000.
 * ===========================================================================
 */

`default_nettype none

module mom_cost_engine
  import mom_pkg::*;
#(
  parameter engine_e ENGINE_ID = ENG_CPU
) (
  // ---- features from stage 1 -----------------------------------------------
  // Session 144: the engine is now a TWO-STAGE pipeline. The first harden
  // measured the whole features -> cost path at 62 ns at ss_100C_1v60 (103
  // cells); a register after t_pred splits it near the middle. `adv` is the
  // pipeline advance from mom_top (high when the stage below can accept), so
  // the five engines move in lockstep with mom_top's cost register and never
  // lose a descriptor under back-pressure.
  input  wire                     clk,
  input  wire                     rst_n,
  input  wire                     adv,
  input  wire  [7:0]              log2_w,      // log2 of work volume
  input  wire  [23:0]             bytes_q,     // operand traffic, linear
  input  wire  signed [8:0]       log2_i,      // log2 of arithmetic intensity
  input  wire  dtype_e            dtype,
  input  wire  opclass_e          op_class,
  input  wire  lat_hint_e         lat_hint,
  input  wire  [3:0]              lambda_sh,   // {enable, log2}, see lambda_sh_of()

  // ---- this engine's parameters --------------------------------------------
  input  wire  eng_param_t        param,

  // ---- dynamic state -------------------------------------------------------
  input  wire  [7:0]              k_cal,       // Q1.7 calibration factor
  input  wire  [7:0]              queue_depth, // outstanding ops on this engine
  input  wire                     engine_busy_full,

  // ---- platform constants (CSR) --------------------------------------------
  input  wire  [3:0]              bw_dma_log2, // DMA bandwidth, bytes/cycle
  input  wire  [3:0]              eps_mem,     // energy per byte moved, 0..15
  input  wire  [3:0]              e_shift,     // energy-to-cycle normalization

  // ---- results -------------------------------------------------------------
  output logic [COST_W-1:0]       cost,
  output logic [COST_W-1:0]       t_pred,      // uncalibrated, stored for calib
  output logic                    valid,       // 0 = mask this engine out now
  output logic                    capable      // 0 = this engine can NEVER do it
);

  // ===========================================================================
  // Capability check
  // ===========================================================================
  // An engine that cannot handle this dtype OR this operation class is removed
  // entirely, before any cost is compared. This is a correctness gate, not an
  // optimization: dispatching FP32 to the INT8 systolic array would produce
  // wrong answers, not slow ones.
  //
  // A full queue also masks the engine. Rather than modelling the wait, we
  // decline to dispatch. The descriptor stays in the input FIFO and is
  // re-evaluated next cycle, by which time occupancy may have changed.
  // ===========================================================================
  // Two independent capability gates. Both are correctness conditions: an
  // engine failing either would compute the wrong answer, not a slow one.
  wire dt_supported  = dtype_ok(param.dtype_msk, dtype);
  wire opc_supported = opc_ok(param.opc_msk, op_class);

  // `capable` and `valid` are deliberately separate signals, and the
  // distinction is the difference between a retry and a hang.
  //
  //   capable = 0   This engine can NEVER execute this descriptor. No amount
  //                 of waiting changes that.
  //   valid   = 0   This engine cannot execute it RIGHT NOW, because its
  //                 dispatch queue is full. Waiting fixes it.
  //
  // Collapsing the two into one signal is what allowed an unsatisfiable
  // descriptor to stall the pipeline forever: the selector saw "nothing
  // available", the descriptor stayed in stage 1, and it retried every cycle
  // until reset. See mom_top's unsupported-descriptor path.
  wire capable_a = dt_supported && opc_supported;
  wire valid_a   = capable_a && !engine_busy_full;

  // ===========================================================================
  // Equation (2): attainable performance in the log domain
  // ===========================================================================
  // log2_i is signed because a memory-bound kernel has I < 1. Clamping the sum
  // at zero is correct: an engine cannot deliver less than one op per cycle
  // and still be worth modelling at this granularity. The clamp also keeps the
  // subtraction in equation (3) from going negative.
  // ===========================================================================
  wire signed [9:0] bw_bound_s = log2_i + $signed({6'd0, param.bw_bytes_log2});
  wire        [3:0] bw_bound   = (bw_bound_s <= 0)  ? 4'd0  :
                                 (bw_bound_s >= 15) ? 4'd15 :
                                 bw_bound_s[3:0];

  wire [3:0] lg_p_att = (bw_bound < param.p_peak_log2) ? bw_bound
                                                       : param.p_peak_log2;

  // Exposed for the testbench to check against the Python reference model.
  // Synthesis prunes it if unused.
  // synthesis translate_off
  wire [3:0] dbg_lg_p_att = lg_p_att;
  // synthesis translate_on

  // ===========================================================================
  // Equations (3) and (4): compute cycles
  // ===========================================================================
  // Saturating subtract: if the work volume is smaller than the engine's
  // per-cycle throughput, the job takes one cycle, not a fraction of one.
  // ===========================================================================
  wire [7:0] lg_t_comp = (log2_w > {4'd0, lg_p_att})
                       ? (log2_w - {4'd0, lg_p_att})
                       : 8'd0;

  // The barrel shift. Clamped at 31 so a pathological descriptor cannot
  // overflow the 32-bit cost word and wrap around into looking cheap.
  wire [4:0]        sh_amt   = (lg_t_comp > 8'd31) ? 5'd31 : lg_t_comp[4:0];
  wire [COST_W-1:0] t_compute = (lg_t_comp > 8'd31) ? COST_SAT
                                                    : (32'd1 << sh_amt);

  // ===========================================================================
  // Equation (5): total predicted cycles
  // ===========================================================================
  // The DMA term uses the platform DMA bandwidth rather than the engine's own,
  // because operands have to arrive before the engine can be bandwidth-bound
  // by its own port. This is the term that makes the TPU lose on small
  // problems: 64 cycles of weight load plus the transfer dwarfs the compute.
  // ===========================================================================
  wire [COST_W-1:0] t_move  = {8'd0, bytes_q} >> bw_dma_log2;
  wire [COST_W-1:0] t_setup = {20'd0, param.t_setup};

  // The latency hint biases against setup cost. A real-time caller would
  // rather run on an idle CPU than wait 64 cycles for a weight load.
  //
  // Expressed as a shift, not a multiply: the multipliers are 1, 2, and 4.
  wire [1:0] setup_sh = (lat_hint == LAT_REALTIME) ? 2'd2 :
                        (lat_hint == LAT_LOW)      ? 2'd1 : 2'd0;
  wire [39:0] t_setup_w = {28'd0, param.t_setup} << setup_sh;

  // ---------------------------------------------------------------------------
  // CRITICAL: this sum MUST be computed wider than COST_W.
  //
  // t_compute saturates to COST_SAT (0xFFFF0000) whenever log2(W) exceeds 31,
  // which happens for any problem above roughly 2^31 operations. A 4000-vector
  // randomized cross-check found that adding even a small t_move to a
  // saturated t_compute overflows 32 bits and WRAPS:
  //
  //     0xFFFF0000 + 0x00020910  =  0x1_0001F910
  //     truncated to 32 bits     =  0x0001F910     (128 KB of cycles)
  //
  // The guard `t_sum > COST_SAT` then passes, because t_sum already wrapped to
  // a small value. An engine that cannot possibly do the work in finite time
  // scored as one of the cheapest available.
  //
  // In silicon this would route every large problem to the scalar CPU, which
  // is the exact opposite of the intended behaviour and would have been very
  // hard to diagnose from performance counters alone.
  //
  // The 40-bit accumulator has 8 bits of headroom over COST_W, which covers
  // the worst case: COST_SAT + (t_setup * 4) + (2^24 >> 0) + 255.
  // ---------------------------------------------------------------------------
  wire [39:0] t_sum_w = {8'd0, t_compute}
                      + t_setup_w
                      + {8'd0, t_move}
                      + {32'd0, queue_depth};

  wire [COST_W-1:0] t_pred_a = (t_sum_w > {8'd0, COST_SAT}) ? COST_SAT : t_sum_w[COST_W-1:0];
  // Pipeline-register state (session 144); the always_ff sits after stage A.
  logic [COST_W-1:0] t_pred_q;
  logic [31:0]       e_ops_q, e_mem_q;
  logic              valid_q, capable_q;
  logic [3:0]        lambda_q;


  // ===========================================================================
  // Equation (6): apply the online calibration factor
  // ===========================================================================
  // k_cal is Q2.6 with 64 meaning "the analytical model was exactly right".
  // A 40-bit intermediate holds the product before the shift. See mom_pkg.sv
  // for why the format moved from Q1.7 to Q2.6.
  // ===========================================================================
  // ---------------------------------------------------------------------------
  // NORMALIZED CALIBRATION MULTIPLY
  //
  // The direct form was `t_pred * k_cal` at 32x8, roughly 1,200 cells, five
  // times over. Full 32-bit precision in the low bits is never observed: the
  // product's only consumer is a comparison against four other engines, and
  // the winner is decided by the high bits.
  //
  // So t_pred is normalized to a 16-bit mantissa plus a shift, the MANTISSA is
  // multiplied by k (16x8, roughly 400 cells), and the result is shifted back.
  //
  //     t_pred = m * 2^e     with m in [2^15, 2^16)
  //     t_cal  = (m * k) >> KCAL_SHIFT << e
  //
  // Relative precision loss is bounded by 2^-16, one part in 65,536. The
  // calibration loop moves k in 1.56% steps, so the discarded bits are four
  // orders of magnitude below the granularity of the thing being computed.
  //
  // Verified by the 25,000-vector cross-check against the reference model,
  // which had to be updated to match: the model mirrors the hardware, not the
  // cleaner algebra.
  // ---------------------------------------------------------------------------
  logic [4:0] tp_e;
  always_comb begin
    if      (t_pred_q[31:16] != 16'd0) tp_e = 5'd16;
    else if (t_pred_q[15:8]  !=  8'd0) tp_e = 5'd8;
    else                             tp_e = 5'd0;
  end

  // Coarse normalization to byte granularity rather than bit granularity. A
  // full leading-zero normalize would need a 32-bit priority encoder and a
  // barrel shifter to recover at most 7 more bits of a quantity already
  // precise to one part in 65,536. Three cases cost three muxes.
  wire [15:0] tp_m = (tp_e == 5'd16) ? t_pred_q[31:16]
                   : (tp_e == 5'd8)  ? t_pred_q[23:8]
                                     : t_pred_q[15:0];

  wire [23:0] cal_prod = tp_m * {8'd0, k_cal};      // 16 x 8

  // Shift back: << tp_e to undo the normalization, >> KCAL_SHIFT for the Q2.6
  // factor. Combined into one signed shift so only one shifter is built.
  wire signed [6:0] cal_sh = $signed({2'b0, tp_e}) - $signed(7'(KCAL_SHIFT));

  wire [47:0] cal_wide = cal_sh >= 0 ? ({24'd0, cal_prod} << cal_sh[5:0])
                                     : ({24'd0, cal_prod} >> (-cal_sh[5:0]));

  wire [COST_W-1:0] t_cal = (cal_wide[47:COST_W] != '0) ? COST_SAT
                                                        : cal_wide[COST_W-1:0];

  // ===========================================================================
  // Equation (7): energy
  // ===========================================================================
  // W is reconstructed from its logarithm, same factor-of-two caveat as above,
  // same reason it does not matter: any systematic scale error is common to
  // all five engines and cancels in the argmin.
  // ===========================================================================
  // W is a power of two by construction: w_lin = 1 << log2_w. So
  //
  //     E_ops = W * eps_op = eps_op << log2_w
  //
  // is EXACT, not an approximation. The multiply form cost about 1,500 cells
  // per engine to compute something a barrel shifter does for 200.
  //
  // The shift is clamped at 31 so an enormous work volume saturates rather
  // than wrapping, matching the t_compute clamp above.
  // ---------------------------------------------------------------------------
  // The three shifts on the energy path collapse into one.
  //
  // Naively the term is
  //
  //     ((eps_op << log2_w) << lambda_log2) >> e_shift
  //
  // which is three barrel shifters on a 40-to-45 bit datapath, and those were
  // the largest remaining cells in this module after the multipliers went.
  // Successive shifts compose, so the whole thing is one shift by the net
  // amount:
  //
  //     net = log2_w + lambda_log2 - e_shift
  //
  // Left when net is positive, right when negative. The identity
  // (a << x) >> y  ==  a << (x-y)  for x >= y, and  a >> (y-x)  otherwise,
  // holds exactly for unsigned integers, so this is not an approximation.
  //
  // One 8-bit source into a 32-bit result with a 6-bit shift amount: about
  // 400 cells, replacing roughly 1,900.
  // ---------------------------------------------------------------------------
  wire [5:0]  w_sh  = (log2_w > 8'd31) ? 6'd31 : {1'b0, log2_w[4:0]};

  wire signed [7:0] net_sh_s = $signed({2'b0, w_sh})
                             + $signed({5'b0, lambda_sh[2:0]})
                             - $signed({4'b0, e_shift});

  // Scaled ops-energy term, computed with the single net shift above.
  wire        net_pos  = ~net_sh_s[7];
  wire [5:0]  net_mag  = net_pos ? net_sh_s[5:0] : (~net_sh_s[5:0] + 6'd1);
  wire        net_ovf  = net_pos && (net_mag > 6'd24);   // would exceed 32 bits

  wire [31:0] e_ops_sc = (log2_w > 8'd31) || net_ovf ? COST_SAT
                       : net_pos ? ({24'd0, param.eps_op} << net_mag)
                                 : ({24'd0, param.eps_op} >> net_mag);

  // The memory term is a genuine multiply: bytes_q is arbitrary. Narrowed from
  // 24x8 to 24x4 by capping eps_mem at 15 (units of 0.25 pJ per byte, so up to
  // 3.75 pJ/byte, which covers external QSPI comfortably). About 350 cells.
  //
  // Scaled the same way, and by the same net amount minus log2_w since bytes_q
  // is already linear.
  wire [27:0] e_mem_raw = bytes_q * {24'd0, eps_mem};
  wire signed [7:0] mem_sh_s = $signed({5'b0, lambda_sh[2:0]})
                             - $signed({4'b0, e_shift});
  wire        mem_pos = ~mem_sh_s[7];
  wire [5:0]  mem_mag = mem_pos ? mem_sh_s[5:0] : (~mem_sh_s[5:0] + 6'd1);
  wire [31:0] e_mem_sc = mem_pos ? ({4'd0, e_mem_raw} << mem_mag)
                                 : ({4'd0, e_mem_raw} >> mem_mag);

  // ===========================================================================
  // Equation (8): the objective
  // ===========================================================================
  // With lambda = 0 (PWR_MAX) the energy term vanishes and this reduces to
  // pure latency minimization. With lambda = 16 (PWR_MIN) energy dominates and
  // the TPU wins almost everything, because 0.5 pJ/op against the CPU's 20
  // pJ/op is a 40x advantage that swamps a 64-cycle setup.
  // ===========================================================================
  // Sum the two scaled energy terms. Note this truncates each term separately
  // before summing, where the previous version summed then truncated once. The
  // two differ by at most 1 cycle-equivalent, and the reference model in
  // tb_mom_model.py mirrors THIS order so the cross-check stays exact.
  //
  // lambda_sh[3] is the enable: PWR_MAX zeroes the energy term entirely and
  // the objective reduces to pure latency minimization.
  // ---------------------------------------------------------------------------
  // THE PIPELINE REGISTER (session 144). Everything above is stage A
  // (features -> t_pred and the raw energy terms). Everything below is
  // stage B (calibration multiply and barrel shift, energy sum, saturate).
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_pred_q <= '0; e_ops_q <= '0; e_mem_q <= '0;
      valid_q <= 1'b0; capable_q <= 1'b0; lambda_q <= '0;
    end else if (adv) begin
      t_pred_q  <= t_pred_a;
      e_ops_q   <= e_ops_sc;
      e_mem_q   <= e_mem_sc;
      valid_q   <= valid_a;
      capable_q <= capable_a;
      lambda_q  <= lambda_sh;
    end
  end
  assign t_pred  = t_pred_q;
  assign valid   = valid_q;
  assign capable = capable_q;

  wire [32:0] e_sum_w = lambda_q[3] ? ({1'b0, e_ops_q} + {1'b0, e_mem_q})
                                    : 33'd0;
  wire [31:0] e_scaled = e_sum_w[32] ? COST_SAT : e_sum_w[31:0];

  wire [COST_W:0] j_sum = {1'b0, t_cal} + {1'b0, e_scaled};

  always_comb begin
    if (!valid)
      cost = {COST_W{1'b1}};              // never selected
    else if (j_sum[COST_W])
      cost = COST_SAT;                    // overflowed, effectively never
    else
      cost = j_sum[COST_W-1:0];
  end

`ifdef FORMAL
  // An invalid engine must present maximum cost, so the selector can never
  // pick it regardless of tie-break order.
  always @(*) begin
    if (!valid) assert (cost == {COST_W{1'b1}});
  end

  // Attainable performance never exceeds peak. This is equation (1) as a
  // machine-checked property rather than a comment.
  always @(*) begin
    assert (lg_p_att <= param.p_peak_log2);
  end
`endif

endmodule

`default_nettype wire

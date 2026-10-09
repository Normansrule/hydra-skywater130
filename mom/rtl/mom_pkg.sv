/*
 * mom_pkg.sv
 *
 * HYDRA-130 - Mathematical Operation MUX: shared types and constants
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS PACKAGE IS FOR
 * ---------------------------------------------------------------------------
 * The MOM decides, in hardware and in three cycles, which compute engine should
 * execute a given unit of work: the scalar CPU, the SIMD unit, the TPU systolic
 * array, the NTT engine, or the crypto engine.
 *
 * It does this by evaluating a roofline cost model per engine and picking the
 * cheapest one, where "cheapest" blends predicted cycles with predicted energy
 * according to a software-supplied power hint.
 *
 * The model is analytical, so it is small. It is also self-correcting: each
 * engine carries a per-op-class scale factor that is updated from measured
 * completion times, so predictions improve on workloads the design was never
 * characterized against. See mom_calibrate.sv.
 *
 * ---------------------------------------------------------------------------
 * WHY A PACKAGE
 * ---------------------------------------------------------------------------
 * Every MOM module needs the same enums and widths. Keeping them here means one
 * place to change a field width, and the compiler catches every module that
 * needed updating. This mirrors asicirific_pkg.sv in the RISC-V core.
 * ---------------------------------------------------------------------------
 */

`default_nettype none

package mom_pkg;

  // -------------------------------------------------------------------------
  // Engine identifiers
  // -------------------------------------------------------------------------
  // Order matters: mom_select.sv uses ENG_N as the width of its one-hot valid
  // mask and iterates 0..ENG_N-1 when finding the argmin. Adding an engine
  // means bumping ENG_N and adding a row to mom_param_rom.sv, nothing else.
  // -------------------------------------------------------------------------
  localparam int unsigned ENG_N = 5;

  typedef enum logic [2:0] {
    ENG_CPU    = 3'd0,  // scalar RV32IMC_Zba pipeline
    ENG_SIMD   = 3'd1,  // 4-lane 32-bit vector unit
    ENG_TPU    = 3'd2,  // 16x16 INT8 output-stationary systolic array
    ENG_NTT    = 3'd3,  // 8-butterfly number-theoretic transform engine
    ENG_CRYPTO = 3'd4   // AES / SHA / HMAC datapath
  } engine_e;

  // -------------------------------------------------------------------------
  // Operation classes
  // -------------------------------------------------------------------------
  // These drive the work-volume formula in mom_features.sv. See PROJECT_PLAN.md
  // section 5.3 for the equation behind each one.
  // -------------------------------------------------------------------------
  typedef enum logic [3:0] {
    OPC_SCALAR  = 4'd0,  // W = M                     (control-flow heavy)
    OPC_ELEMENT = 4'd1,  // W = M                     (a[i] op b[i])
    OPC_REDUCE  = 4'd2,  // W = M                     (sum, max, argmax)
    OPC_GEMM    = 4'd3,  // W = 2*M*N*K
    OPC_CONV2D  = 4'd4,  // W = 2*M*N*Kh*Kw*Cin
    OPC_FFT     = 4'd5,  // W = 5*N*log2(N)
    OPC_NTT     = 4'd6,  // W = (N/2)*log2(N)*CBF
    OPC_CIPHER  = 4'd7,  // W = bytes * cycles_per_byte
    OPC_HASH    = 4'd8   // W = blocks * cycles_per_block
  } opclass_e;

  // -------------------------------------------------------------------------
  // Data types
  // -------------------------------------------------------------------------
  // Engines advertise which of these they support via a bitmask in the
  // parameter ROM. An engine that cannot handle the descriptor's dtype is
  // masked out of the selection entirely, before any cost is compared.
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    DT_INT8   = 3'd0,
    DT_INT16  = 3'd1,
    DT_INT32  = 3'd2,
    DT_FP16   = 3'd3,
    DT_FP32   = 3'd4,
    DT_POLY_Q = 3'd5   // polynomial coefficients mod q, for the NTT engine
  } dtype_e;

  // -------------------------------------------------------------------------
  // Hints
  // -------------------------------------------------------------------------
  // latency_hint biases toward engines with low setup cost. power_hint sets
  // LAMBDA, the weight on the energy term in the objective function.
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    LAT_THROUGHPUT = 2'd0,  // maximize work per second, setup cost is fine
    LAT_BALANCED   = 2'd1,
    LAT_LOW        = 2'd2,  // penalize setup cost heavily
    LAT_REALTIME   = 2'd3   // hard deadline: pick the lowest worst-case latency
  } lat_hint_e;

  typedef enum logic [1:0] {
    PWR_MAX      = 2'd0,   // LAMBDA = 0,  ignore energy entirely
    PWR_BALANCED = 2'd1,   // LAMBDA = 1
    PWR_LOW      = 2'd2,   // LAMBDA = 4
    PWR_MIN      = 2'd3    // LAMBDA = 16
  } pwr_hint_e;

  // LAMBDA is returned as {enable, log2} rather than as a value.
  //
  // Every lambda in the table is a power of two (0, 1, 4, 16), so the energy
  // weighting `E * lambda` is exactly `E << log2(lambda)` with a separate
  // zero case. Synthesis showed the multiply form costing roughly 1,400 cells
  // per engine, five times over, for an operation that is a barrel shift.
  //
  // Bit [3] is the enable, bits [2:0] the shift amount.
  function automatic logic [3:0] lambda_sh_of(input pwr_hint_e h);
    case (h)
      PWR_MAX:      lambda_sh_of = 4'b0_000;   // disabled: latency only
      PWR_BALANCED: lambda_sh_of = 4'b1_000;   // x1
      PWR_LOW:      lambda_sh_of = 4'b1_010;   // x4
      PWR_MIN:      lambda_sh_of = 4'b1_100;   // x16
      default:      lambda_sh_of = 4'b1_000;
    endcase
  endfunction

  // -------------------------------------------------------------------------
  // Work descriptor
  // -------------------------------------------------------------------------
  // 128 bits, pushed by software through a CSR pair or synthesized by the
  // decode stage when it recognizes a loop pattern. Packed rather than a
  // struct-of-arrays because it crosses a FIFO and we want one write port.
  // -------------------------------------------------------------------------
  localparam int unsigned WD_W = 128;

  typedef struct packed {
    opclass_e            op_class;    //   4
    dtype_e              dtype;       //   3
    lat_hint_e           lat_hint;    //   2
    pwr_hint_e           pwr_hint;    //   2
    logic [15:0]         dim_m;       //  16
    logic [15:0]         dim_n;       //  16
    logic [15:0]         dim_k;       //  16
    logic [23:0]         bytes;       //  24  operand traffic Q
    logic [1:0]          src_loc;     //   2  0=L1 1=scratch 2=ext 3=reserved
    logic [7:0]          tag;         //   8  returned with completion
    logic [34:0]         reserved;    //  35
  } work_desc_t;                      // ---
                                      // 128

  // -------------------------------------------------------------------------
  // Engine parameters, one row per engine in mom_param_rom.sv
  // -------------------------------------------------------------------------
  // p_peak    : ops per cycle at full utilization, as log2 to keep the divide
  //             in mom_cost_engine.sv down to a barrel shift
  // t_setup   : fixed dispatch cost in cycles (weight load, DMA program, etc.)
  // bw_bytes  : operand bandwidth in bytes per cycle, also log2
  // eps_op    : energy per op in pJ, Q4.4 fixed point
  // dtype_msk : which dtype_e values this engine accepts
  // -------------------------------------------------------------------------
  // opc_msk was added after a smoke test caught OPC_SCALAR being dispatched to
  // the SIMD unit. The cost model had no way to know that scalar control code
  // carries loop-carried dependencies and cannot vectorize at all: it checked
  // only whether the engine understood the DATA TYPE, never whether it could
  // perform the OPERATION. That is a correctness hole, not a tuning issue, and
  // it would have produced wrong answers in silicon rather than slow ones.
  //
  // Capability now has two independent gates, both hard masks applied before
  // any cost is compared:
  //     dtype_msk  can this engine represent these numbers?
  //     opc_msk    can this engine perform this kind of operation?
  typedef struct packed {
    logic [3:0]  p_peak_log2;
    logic [11:0] t_setup;
    logic [3:0]  bw_bytes_log2;
    logic [7:0]  eps_op;
    logic [5:0]  dtype_msk;
    logic [8:0]  opc_msk;
  } eng_param_t;

  localparam int unsigned EPARAM_W = 43;   // 4+12+4+8+6+9

  // -------------------------------------------------------------------------
  // Fixed-point conventions
  // -------------------------------------------------------------------------
  // Cost is carried as a 32-bit unsigned cycle count. Predictions above
  // COST_SAT are clamped, which both prevents overflow in the objective sum and
  // expresses "this engine is a terrible idea" without needing a wider adder.
  //
  // The calibration factor k_e is Q1.7: 128 means "prediction was exactly
  // right", 64 means "the engine was twice as fast as predicted".
  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // floor(log2(v)), returning 0 for v == 0
  // -------------------------------------------------------------------------
  // Implemented as a five-level binary search rather than a priority encoder
  // over a variable bit-select. Three reasons, and the first one is a bug that
  // bit us:
  //
  //   1. CORRECTNESS. A variable bit-select `v[i]` inside a function called
  //      from an always_comb block is not supported by Icarus Verilog. It does
  //      not error, it warns "all bits will be included" and returns garbage.
  //      Silent wrong answers in simulation are the worst possible failure
  //      mode, and this form has no variable selects at all.
  //
  //   2. SYNTHESIS. This unrolls to 5 levels of compare-and-shift, roughly
  //      60 gates with a depth of 5. A 32-input priority encoder is wider and
  //      some tools infer a sequential search from the early-exit form.
  //
  //   3. PORTABILITY. Constant part-selects and shifts work everywhere.
  //
  // The structure is the standard logarithmic reduction: test the top half,
  // and if anything is set, add that half's width to the result and shift it
  // down. Repeat with halves of 16, 8, 4, 2, 1.
  // -------------------------------------------------------------------------
  function automatic logic [7:0] flog2(input logic [31:0] v);
    logic [7:0]  r;
    logic [31:0] t;
    begin
      r = 8'd0;
      t = v;
      if (t[31:16] != 16'd0) begin r = r + 8'd16; t = t >> 16; end
      if (t[15:8]  !=  8'd0) begin r = r + 8'd8;  t = t >> 8;  end
      if (t[7:4]   !=  4'd0) begin r = r + 8'd4;  t = t >> 4;  end
      if (t[3:2]   !=  2'd0) begin r = r + 8'd2;  t = t >> 2;  end
      if (t[1]     !=  1'b0) begin r = r + 8'd1;               end
      flog2 = r;
    end
  endfunction

  // -------------------------------------------------------------------------
  // dtype capability test.
  //
  // Written as a shift rather than `mask[dtype]` because indexing a packed
  // field with an enum-typed variable is not portable. The shift is identical
  // hardware: a 6:1 mux either way.
  // -------------------------------------------------------------------------
  function automatic logic dtype_ok(input logic [5:0] mask, input dtype_e dt);
    dtype_ok = (mask >> dt) & 1'b1;
  endfunction

  function automatic logic opc_ok(input logic [8:0] mask, input opclass_e oc);
    opc_ok = (mask >> oc) & 1'b1;
  endfunction

  localparam int unsigned COST_W    = 32;
  localparam logic [31:0] COST_SAT  = 32'hFFFF_0000;
  // -------------------------------------------------------------------------
  // Calibration factor format: Q2.6, unity = 64.
  //
  // The first version used Q1.7 with unity = 128, giving a correction range of
  // [K_MIN/128, K_MAX/128] = [0.125x, 1.99x]. The closed-loop testbench showed
  // why that is the wrong choice: an engine three times slower than the
  // analytical model predicts SATURATES at K_MAX and the calibration silently
  // stops compensating.
  //
  // That asymmetry points the wrong way. An analytical cost model built from
  // datasheet peak throughput is nearly always OPTIMISTIC about real hardware,
  // so the upward correction range is the one that needs headroom, and 1.99x
  // is not enough.
  //
  // Q2.6 gives [4/64, 255/64] = [0.0625x, 3.98x]: double the upward range for
  // the same eight bits. The relative step is unchanged, since ALPHA scales
  // the step with k itself, so convergence RATE is identical. Only the
  // absolute resolution halves, from 0.78% to 1.56% of unity, which is far
  // finer than the 6.25% step the loop actually moves in.
  // -------------------------------------------------------------------------
  localparam int unsigned KCAL_W     = 8;
  localparam int unsigned KCAL_SHIFT = 6;    // Q2.6
  localparam logic [7:0]  KCAL_UNITY = 8'd64;
  localparam int unsigned KCAL_ALPHA = 4;    // step = k >> 4, see mom_calibrate.sv

endpackage

`default_nettype wire

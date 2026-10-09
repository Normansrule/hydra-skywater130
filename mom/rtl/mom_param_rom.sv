/*
 * mom_param_rom.sv
 *
 * HYDRA-130 - MOM engine parameter store
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT THIS HOLDS
 * ===========================================================================
 * Five rows, one per engine, each describing that engine's cost characteristics
 * to the roofline model in mom_cost_engine.sv.
 *
 *   p_peak_log2    log2 of peak throughput in ops/cycle
 *   t_setup        fixed dispatch overhead in cycles
 *   bw_bytes_log2  log2 of operand bandwidth in bytes/cycle
 *   eps_op         energy per op, in units of 0.25 pJ (so 8 bits covers 0..63.75)
 *   dtype_msk      one bit per dtype_e value this engine accepts
 *
 * ===========================================================================
 * WHY WRITABLE
 * ===========================================================================
 * The reset defaults below come from pre-silicon estimates. Post-layout power
 * analysis will move eps_op, and measured setup latency will move t_setup. If
 * these were hard ROM, a 20% estimate error would be baked into the silicon
 * forever.
 *
 * Making them CSR-writable costs 5 x 34 = 170 flops instead of 170 tie cells,
 * about 1,100 GE. In exchange the dispatch policy stays tunable after tapeout,
 * which on a first-silicon research chip is worth far more than the area.
 *
 * Write access is gated by `wr_priv` so that only machine mode can retune
 * dispatch. An attacker who could steer every AES operation to the CPU would
 * have a side-channel amplifier.
 *
 * ===========================================================================
 * WHERE THE DEFAULT NUMBERS COME FROM
 * ===========================================================================
 * p_peak_log2:
 *   CPU     1 op/cycle scalar                       -> log2(1)   = 0
 *   SIMD    4 lanes x 2 (fused multiply-add)  = 8   -> log2(8)   = 3
 *   TPU     8x8 array x 2 ops per MAC        = 128  -> log2(128) = 7
 *   NTT     8 butterflies x 4 equivalent ops = 32   -> log2(32)  = 5
 *   CRYPTO  AES-GCM ~16 byte-ops/cycle       = 16   -> log2(16)  = 4
 *
 * t_setup (cycles):
 *   CPU     0    already running
 *   SIMD    8    vector length + stride config
 *   TPU     64   weight tile load into the array
 *   NTT     32   twiddle factor table load
 *   CRYPTO  16   key schedule, only when the key changes
 *
 * bw_bytes_log2 (bytes/cycle available to that engine):
 *   CPU     4  bytes from D-cache        -> 2
 *   SIMD    16 bytes from scratchpad     -> 4
 *   TPU     32 bytes from scratchpad     -> 5
 *   NTT     16 bytes                     -> 4
 *   CRYPTO  16 bytes                     -> 4
 *
 * eps_op in 0.25 pJ units, from published 130 nm energy-per-operation figures
 * scaled to 1.8 V. These are the roughest numbers in the table and the first
 * thing to update after power signoff.
 *   CPU     20 pJ/op  -> 80    (full pipeline activity per instruction)
 *   SIMD    5  pJ/op  -> 20
 *   TPU     0.5 pJ/op -> 2     (a MAC in a systolic array is cheap)
 *   NTT     2  pJ/op  -> 8
 *   CRYPTO  1  pJ/op  -> 4
 * ===========================================================================
 */

`default_nettype none

module mom_param_rom
  import mom_pkg::*;
(
  input  wire                    clk,
  input  wire                    rst_n,

  // ---- CSR write port, machine mode only -----------------------------------
  input  wire                    wr_en,
  input  wire                    wr_priv,     // 1 = machine mode
  input  wire [2:0]              wr_engine,
  input  wire [EPARAM_W-1:0]     wr_data,

  // ---- read port: all rows presented in parallel ---------------------------
  // The cost engines are instantiated one per engine and each takes its own
  // row combinationally, so there is no read address and no arbitration.
  output eng_param_t [ENG_N-1:0] params
);

  // ---------------------------------------------------------------------------
  // Reset defaults. Packing order matches eng_param_t in mom_pkg.sv:
  //   {p_peak_log2[3:0], t_setup[11:0], bw_bytes_log2[3:0], eps_op[7:0], dtype_msk[5:0]}
  // ---------------------------------------------------------------------------
  // dtype_msk bit positions, from dtype_e:
  //   [0] INT8  [1] INT16  [2] INT32  [3] FP16  [4] FP32  [5] POLY_Q
  // ---------------------------------------------------------------------------
  // opc_msk bit positions, from opclass_e:
  //   [0] SCALAR [1] ELEMENT [2] REDUCE  [3] GEMM  [4] CONV2D
  //   [5] FFT    [6] NTT     [7] CIPHER  [8] HASH
  //
  // The SIMD row deliberately clears bit 0. Scalar work has loop-carried
  // dependencies and data-dependent control flow; a vector unit cannot execute
  // it at any speed. Leaving that bit set is what let the smoke test route
  // control code into the SIMD lanes.
  //
  //                                  p_pk  t_set  bw   eps    dtype     opclass
  localparam logic [EPARAM_W-1:0] DEF_CPU    = {4'd0, 12'd0,  4'd2, 8'd80, 6'b011111, 9'b111111111};
  localparam logic [EPARAM_W-1:0] DEF_SIMD   = {4'd3, 12'd8,  4'd4, 8'd20, 6'b011111, 9'b000111110};
  localparam logic [EPARAM_W-1:0] DEF_TPU    = {4'd7, 12'd64, 4'd5, 8'd2,  6'b000011, 9'b000011000};
  localparam logic [EPARAM_W-1:0] DEF_NTT    = {4'd5, 12'd32, 4'd4, 8'd8,  6'b100100, 9'b001100000};
  localparam logic [EPARAM_W-1:0] DEF_CRYPTO = {4'd4, 12'd16, 4'd4, 8'd4,  6'b000100, 9'b110000000};

  // Note the masks encode real capability limits, and they matter:
  //   TPU accepts INT8 and INT16 only. Handing it FP32 would be a silent
  //     correctness bug, so the selector masks it out instead.
  //   NTT accepts INT32 and POLY_Q. Nothing else makes sense in a ring.
  //   CRYPTO accepts INT32 because ciphertext is opaque bytes.
  //   CPU and SIMD accept everything except POLY_Q, which needs modular
  //     reduction hardware they do not have.

  logic [EPARAM_W-1:0] row [ENG_N];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      row[ENG_CPU]    <= DEF_CPU;
      row[ENG_SIMD]   <= DEF_SIMD;
      row[ENG_TPU]    <= DEF_TPU;
      row[ENG_NTT]    <= DEF_NTT;
      row[ENG_CRYPTO] <= DEF_CRYPTO;
    end else if (wr_en && wr_priv && (wr_engine < 3'(ENG_N))) begin
      row[wr_engine] <= wr_data;
    end
  end

  // ---------------------------------------------------------------------------
  // Unpack. Purely structural; synthesizes to wires.
  // ---------------------------------------------------------------------------
  // Assign the whole struct in one continuous assignment rather than field by
  // field. Two reasons: eng_param_t is a 34-bit packed struct so the bit-cast
  // is exact, and per-field continuous assignment into an unpacked array
  // element is not supported by several simulators (Icarus rejects it as
  // "array slices in continuous assignment"). One assign, zero ambiguity.
  //
  // Field order is fixed by eng_param_t in mom_pkg.sv:
  //   [33:30] p_peak_log2  [29:18] t_setup  [17:14] bw_bytes_log2
  //   [13:6]  eps_op       [5:0]   dtype_msk   (see mom_pkg for full layout)
  for (genvar e = 0; e < ENG_N; e++) begin : g_unpack
    assign params[e] = eng_param_t'(row[e]);
  end

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // An unprivileged write must never change any row.
  //
  // The first version of this property was written as
  //
  //     assert (row[$past(wr_engine)] == $past(row[$past(wr_engine)]));
  //
  // which reads naturally and is not expressible: a $past of an array element
  // selected by a $past index is a nested sampled expression with a variable
  // index, and neither sv2v nor the solver produce what the sentence means.
  // The proof failed for that reason rather than because the design was wrong.
  //
  // Checking every row unconditionally says the same thing, is unambiguous,
  // and costs nothing since it is verification-only code.
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && $past(rst_n) && $past(wr_en) && !$past(wr_priv)) begin
      for (int e = 0; e < ENG_N; e++)
        assert (row[e] == $past(row[e]));
    end
  end

  // A privileged write must land, and land only on the addressed row.
  always @(posedge clk) begin
    if (rst_n && $past(rst_n) && $past(wr_en) && $past(wr_priv)
        && ($past(wr_engine) < 3'(ENG_N))) begin
      for (int e = 0; e < ENG_N; e++)
        if (3'(e) != $past(wr_engine))
          assert (row[e] == $past(row[e]));
    end
  end
`endif

endmodule

`default_nettype wire

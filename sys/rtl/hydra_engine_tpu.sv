/*
 * hydra_engine_tpu.sv -- the real TPU behind the crossbar's engine port
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY THIS ADAPTER EXISTS
 * ===========================================================================
 * tpu_top needs operands; the crossbar carries none. In the finished chip a
 * direct memory access engine streams them from a scratchpad. There is no
 * scratchpad yet, and inventing a memory interface to fill the gap would put
 * an unverified block between the dispatcher and the only real engine.
 *
 * So the operands come from a PATTERN GENERATOR: deterministic, one slice per
 * cycle, derived from the row, column and k index. That is honest about what
 * it is -- the arithmetic is real, the array is real, the timing is real, and
 * the operands are synthetic. It makes the engine self-contained enough to
 * run on a board and be checked, which is what the bring-up needs first.
 *
 *   a[i][k] = ((3*i + 5*k) & 15) - 8
 *   b[k][j] = ((7*j + 11*k) & 15) - 8
 *
 * Both fit INT8 and both are reproducible in Python, so the expected result
 * is computable without reading it out of the hardware.
 *
 * ===========================================================================
 * WHAT IT REPORTS
 * ===========================================================================
 * Reading N*N results back through a 4-wire bus per dispatch would dominate
 * the bring-up. Instead the adapter keeps a running checksum of every result
 * element and exposes it. A checksum catches a wrong array, a wrong drain
 * order, a dropped element and a stalled feeder; it does not localise the
 * fault, which is what the simulation bench is for.
 */
`default_nettype none

module hydra_engine_tpu
  import tpu_pkg::*;
#(
  parameter int unsigned N    = N_PE,
  parameter int unsigned WD_W = 128,
  parameter int unsigned TAGW = 4
) (
  input  wire              clk,
  input  wire              rst_n,

  // ---- engine port ---------------------------------------------------------
  input  wire              eng_valid,
  output logic             eng_ready,
  input  wire [WD_W-1:0]   eng_wd,
  input  wire [TAGW-1:0]   eng_tag,
  output logic             eng_done,
  output logic [TAGW-1:0]  eng_done_tag,

  // ---- observation ---------------------------------------------------------
  output logic [31:0]      checksum,     // running over every result element
  output logic [15:0]      tiles_done,
  output tpu_status_e      last_status
);
  // ---------------------------------------------------------------------------
  // Operand pattern. Registered on the slice index so the generator is a
  // small adder chain rather than a multiplier per lane.
  // ---------------------------------------------------------------------------
  logic [KW-1:0]         k_idx_q;
  logic [KW-1:0]          m_q, n_q;      // tile shape, latched at accept
  logic signed [AW-1:0]  op_a [N];
  logic signed [AW-1:0]  op_b [N];
  wire                   op_ready, op_valid;

  // Lanes outside the tile carry ZERO. Without this the generator fills all
  // N lanes whatever M and N say, the processing elements outside the tile
  // accumulate real products, and the results there are not zero -- which
  // is what the checksum comparison caught on a 2x3 tile. The array itself
  // has no notion of a partial tile; masking is the operand source's job,
  // and in silicon it will be the direct memory access engine's.
  always_comb begin
    for (int i = 0; i < N; i++) begin
      op_a[i] = (KW'(i) < m_q) ? signed'({4'b0, 4'(3*i + 5*k_idx_q)}) - 8'sd8 : '0;
      op_b[i] = (KW'(i) < n_q) ? signed'({4'b0, 4'(7*i + 11*k_idx_q)}) - 8'sd8 : '0;
    end
  end

  // The generator always has a slice ready: it is arithmetic, not memory.
  // Real operands will not be, which is why tb_tpu stalls at random.
  assign op_valid = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      k_idx_q <= '0; m_q <= '0; n_q <= '0;
    end else if (eng_valid && eng_ready) begin
      k_idx_q <= '0;                                        // new tile
      m_q     <= eng_wd[116:101];
      n_q     <= eng_wd[100:85];
    end else if (op_valid && op_ready) begin
      k_idx_q <= k_idx_q + KW'(1);
    end
  end

  // ---------------------------------------------------------------------------
  // The engine
  // ---------------------------------------------------------------------------
  wire                   res_valid, res_last;
  wire signed [ACCW-1:0] res_data;

  tpu_top #(.N(N), .WD_W(WD_W), .TAGW(TAGW)) u_tpu (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .op_ready(op_ready), .op_valid(op_valid), .op_a(op_a), .op_b(op_b),
    .res_valid(res_valid), .res_data(res_data), .res_last(res_last),
    .status(last_status));

  // ---------------------------------------------------------------------------
  // Observation. The checksum mixes position as well as value, so two results
  // swapping places changes it -- a plain sum would not notice, and the drain
  // order was wrong once already.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      checksum   <= '0;
      tiles_done <= '0;
    end else begin
      if (res_valid) checksum <= {checksum[30:0], checksum[31]} ^ res_data;
      if (eng_done)  tiles_done <= tiles_done + 16'd1;
    end
  end

  wire _unused = &{res_last, 1'b0};

endmodule

`default_nettype wire

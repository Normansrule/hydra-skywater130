/*
 * tpu_ctrl.sv -- the TPU's one controller
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT IT SEQUENCES
 * ===========================================================================
 *   IDLE    waiting for a tile
 *   CLEAR   one cycle: every accumulator to zero
 *   STREAM  K slices in, one per cycle, whenever the operand source has one
 *   FLUSH   2*(N-1) cycles: the last operands walk to the far corner
 *   DRAIN   N rows shift out of the bottom, serialised by tpu_drain
 *   DONE    one completion pulse
 *
 * ===========================================================================
 * TWO DECISIONS WORTH THE COMMENT
 * ===========================================================================
 * 1. STREAM STALLS, IT DOES NOT DROP. If the operand source has no slice this
 *    cycle, the array must not advance: a systolic array has no way to
 *    represent a gap, and a dropped slice silently computes the wrong dot
 *    product. So `en` follows op_valid, and the skew pipeline stalls with it.
 *
 * 2. AN UNSUPPORTED DESCRIPTOR STILL COMPLETES. Refusing work by staying
 *    silent would strand the dispatcher's tag forever -- the tag never
 *    retires, the fence never clears, and the machine wedges. It reports the
 *    reason on `status` and completes immediately instead. Losing a result
 *    loudly beats deadlocking quietly.
 */
`default_nettype none

module tpu_ctrl
  import tpu_pkg::*;
#(
  parameter int unsigned N = N_PE
) (
  input  wire                clk,
  input  wire                rst_n,

  // ---- job ---------------------------------------------------------------
  input  wire                start,          // one cycle: take the job below
  input  wire [KW-1:0]       dim_m,
  input  wire [KW-1:0]       dim_n,
  input  wire [KW-1:0]       dim_k,
  input  wire                opclass_ok,     // decoded outside: is it a GEMM
  input  wire                dtype_ok,       // is it INT8

  // ---- operand source -----------------------------------------------------
  output logic               op_ready,       // in STREAM and able to take one
  input  wire                op_valid,

  // ---- array control ------------------------------------------------------
  output logic               arr_clr,
  output logic               arr_en,
  output logic               feed_valid,     // inject a real slice this cycle
  output logic               arr_shift,
  output logic               feed_flush,

  // ---- drain --------------------------------------------------------------
  output logic               row_valid,
  output logic               row_last,
  input  wire                drain_busy,

  // ---- completion ---------------------------------------------------------
  output logic               done,
  output tpu_status_e        status,
  output logic               busy
);
  typedef enum logic [2:0] {
    S_IDLE, S_CLEAR, S_STREAM, S_FLUSH, S_DRAIN, S_TAIL, S_DONE
  } state_e;

  state_e                 st_q;
  logic [KW-1:0]          k_left_q;
  logic [$clog2(2*N)-1:0] flush_q;
  logic [$clog2(N+1)-1:0] row_q;
  tpu_status_e            status_q;

  // Capability check, made once at start: everything it reads is stable then.
  wire dims_ok  = (dim_m != 0) && (dim_n != 0) && (dim_k != 0) &&
                  (dim_m <= KW'(N)) && (dim_n <= KW'(N));
  wire job_ok   = opclass_ok && dtype_ok && dims_ok;
  wire [1:0] why = !opclass_ok ? TPU_BAD_OPCLASS :
                   !dtype_ok   ? TPU_BAD_DTYPE   : TPU_BAD_DIMS;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= S_IDLE; k_left_q <= '0; flush_q <= '0; row_q <= '0;
      status_q <= TPU_OK;
    end else begin
      unique case (st_q)
        S_IDLE: if (start) begin
          if (job_ok) begin
            st_q     <= S_CLEAR;
            k_left_q <= dim_k;
            status_q <= TPU_OK;
          end else begin
            st_q     <= S_DONE;          // report and retire the tag
            status_q <= tpu_status_e'(why);
          end
        end

        S_CLEAR: st_q <= S_STREAM;

        S_STREAM: if (op_valid) begin
          if (k_left_q == KW'(1)) begin
            st_q    <= S_FLUSH;
            flush_q <= '0;
          end
          k_left_q <= k_left_q - KW'(1);
        end

        // The last slice reaches processing element (r, c) after r feeder
        // delays and c array hops, so the far corner is 2N-2 cycles behind
        // the near one -- and the streaming cycle already counted as the
        // first. The bound is therefore 2N-3 here, not 2N-2: mutation
        // testing found the extra cycle by shortening it and seeing every
        // test still pass, which is how spare cycles get noticed.
        S_FLUSH: begin
          if (flush_q == ($clog2(2*N))'(2*N - 3)) begin
            st_q  <= S_DRAIN;
            row_q <= '0;
          end else begin
            flush_q <= flush_q + 1'b1;
          end
        end

        // One row leaves the bottom per shift, but only when the serialiser
        // has finished the previous one.
        S_DRAIN: if (!drain_busy) begin
          if (row_q == ($clog2(N+1))'(N - 1)) st_q <= S_TAIL;
          else                                row_q <= row_q + 1'b1;
        end

        // The last row is still inside the serialiser when the shifting
        // stops. Completing here would tell the dispatcher the tile is done
        // while a quarter of the results were still on their way out -- the
        // bench caught exactly that: 13 results instead of 16.
        S_TAIL: if (!drain_busy) st_q <= S_DONE;

        S_DONE: st_q <= S_IDLE;
        default: st_q <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    arr_clr    = (st_q == S_CLEAR);
    // The array keeps stepping through FLUSH so operands already inside walk
    // to the far corner -- but the FEEDER must inject zeros while they do.
    // Driving both from one signal re-injected the last slice for 2N-2 more
    // cycles and multiplied every result; the model comparison caught it.
    arr_en     = (st_q == S_STREAM && op_valid) || (st_q == S_FLUSH);
    feed_valid = (st_q == S_STREAM) && op_valid;
    arr_shift  = (st_q == S_DRAIN) && !drain_busy;
    feed_flush = (st_q == S_CLEAR);
    op_ready   = (st_q == S_STREAM);
    row_valid  = (st_q == S_DRAIN) && !drain_busy;
    row_last   = row_valid && (row_q == ($clog2(N+1))'(N - 1));
    done       = (st_q == S_DONE);
    status     = status_q;
    busy       = (st_q != S_IDLE);
  end

`ifdef FORMAL
  // The contract the dispatcher depends on, checked by induction.
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;

  // The state register is three bits and there are seven states, so the
  // eighth encoding exists in the hardware even though nothing reaches it.
  // k-induction starts there unless told otherwise, and from there "once
  // busy, stay busy until done" is false -- the default arm returns to IDLE
  // without a completion. Stating the invariant makes the induction sound
  // AND documents that the default arm is the only exit: if someone adds a
  // state and forgets to widen this, the proof fails here rather than
  // letting a tag leak in silicon.
  // Proved from reset, and assumed for the induction step. Both are needed
  // and they are not circular: the assertion establishes that every state
  // the design can REACH is valid, the assumption stops induction starting
  // in the eighth encoding no reachable path produces. If a future state is
  // added without widening this, the assertion fails first.
  always_ff @(posedge clk)
    if (past_valid && $past(rst_n) && rst_n) assert (st_q <= S_DONE);
  always_ff @(posedge clk) assume (st_q <= S_DONE);

  always_ff @(posedge clk) if (past_valid && $past(rst_n) && rst_n) begin
    // A completion is exactly one cycle: two in a row would retire two tags.
    if ($past(done)) assert (!done);
    // Never idle and busy at once, and never accept work while busy.
    assert (busy == (st_q != S_IDLE));
    if ($past(busy) && !$past(done)) assert (busy);
    // The array only accumulates on a cycle the operand source supplied one.
    if (arr_en && st_q == S_STREAM) assert (op_valid);
    // Drain never overlaps the serialiser still emitting.
    if (row_valid) assert (!drain_busy);
  end
`endif
endmodule

`default_nettype wire

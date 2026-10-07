/*
 * simd_ctrl.sv -- the SIMD unit's one controller
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 *   IDLE     waiting
 *   RUN      consume K groups; ELEMENT streams results, REDUCE accumulates
 *   TAIL     let the last group leave the pipeline and the serialiser empty
 *   EMIT     REDUCE only: present the single accumulated result
 *   DONE     one completion pulse
 *
 * Two behaviours worth stating, both learned the hard way on the TPU:
 *
 *  - completion waits for the RESULTS, not for the last input. A controller
 *    that reports done when the last operand went in tells the dispatcher a
 *    tag is free while a quarter of the answers are still in flight.
 *  - a descriptor this engine cannot execute still completes, with a reason
 *    on `status`. Silence would strand the tag and wedge the machine.
 */
`default_nettype none
module simd_ctrl
  import simd_pkg::*;
#(
  parameter int unsigned N = NLANE
) (
  input  wire              clk,
  input  wire              rst_n,

  input  wire              start,
  input  wire [CNTW-1:0]   dim_k,          // groups of N elements
  input  wire              opclass_ok,     // ELEMENT, SCALAR or REDUCE
  input  wire              is_reduce,
  input  wire              dtype_ok,

  output logic             op_ready,
  input  wire              op_valid,

  output logic             lanes_valid,    // feed the lanes this cycle
  output logic             acc_clr,
  output logic             emit_group,     // hand a group to the serialiser
  output logic             emit_last,
  input  wire              serial_busy,
  input  wire              lanes_out_valid,

  output logic             done,
  output simd_status_e     status,
  output logic             busy
);
  typedef enum logic [2:0] {S_IDLE, S_RUN, S_TAIL, S_EMIT, S_DONE} state_e;

  state_e            st_q;
  logic [CNTW-1:0]   k_left_q;
  logic              reduce_q;
  logic [1:0]        tail_q;
  simd_status_e      status_q;

  wire dims_ok = (dim_k != 0);
  wire job_ok  = opclass_ok && dtype_ok && dims_ok;
  wire [1:0] why = !opclass_ok ? SIMD_BAD_OPCLASS :
                   !dtype_ok   ? SIMD_BAD_DTYPE   : SIMD_BAD_DIMS;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= S_IDLE; k_left_q <= '0; reduce_q <= 1'b0; tail_q <= '0;
      status_q <= SIMD_OK;
    end else begin
      unique case (st_q)
        S_IDLE: if (start) begin
          reduce_q <= is_reduce;
          if (job_ok) begin
            st_q <= S_RUN; k_left_q <= dim_k; status_q <= SIMD_OK;
          end else begin
            st_q <= S_DONE; status_q <= simd_status_e'(why);
          end
        end

        S_RUN: if (op_valid && op_ready) begin
          if (k_left_q == CNTW'(1)) begin
            st_q   <= S_TAIL;
            tail_q <= 2'd0;
          end
          k_left_q <= k_left_q - CNTW'(1);
        end

        // One cycle for the lane registers, then wait for the serialiser.
        S_TAIL: begin
          if (tail_q != 2'd2) tail_q <= tail_q + 2'd1;
          else if (!serial_busy && !lanes_out_valid)
            st_q <= reduce_q ? S_EMIT : S_DONE;
        end

        S_EMIT: if (!serial_busy) st_q <= S_DONE;

        S_DONE: st_q <= S_IDLE;
        default: st_q <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    // ELEMENT results go to the serialiser, so a new group may only enter
    // when the previous one has finished leaving AND no result is still in
    // the lane register. Checking serial_busy alone let a second group in
    // one cycle early: its results reached a serialiser that was by then
    // busy with the first group, and were dropped silently -- the model
    // comparison saw 12 results where 20 were due.
    op_ready    = (st_q == S_RUN) &&
                  (reduce_q || (!serial_busy && !lanes_out_valid));
    lanes_valid = (st_q == S_RUN) && op_valid && op_ready;
    acc_clr     = (st_q == S_IDLE) && start;
    emit_group  = !reduce_q && lanes_out_valid;
    emit_last   = emit_group && (st_q == S_TAIL);
    done        = (st_q == S_DONE);
    status      = status_q;
    busy        = (st_q != S_IDLE);
  end

`ifdef FORMAL
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;

  // The eighth state encoding exists and nothing reaches it; assumed for
  // induction, asserted from reset. Same reasoning as tpu_ctrl.
  always_ff @(posedge clk)
    if (past_valid && $past(rst_n) && rst_n) assert (st_q <= S_DONE);
  always_ff @(posedge clk) assume (st_q <= S_DONE);

  // ---- what the neighbouring modules promise -----------------------------
  // These are not conveniences: they are simd_lanes' and simd_serial's
  // contracts, and without them the solver is free to raise either input at
  // any moment, which makes "no lane result is ever dropped" unprovable
  // here rather than false. If either module stops honouring its side, its
  // own bench fails -- and tb_simd covers both paths together.
  //   lanes:     a result appears exactly one cycle after it is fed
  //   serialiser: it only becomes busy by being loaded
  always_ff @(posedge clk) if (past_valid && $past(rst_n) && rst_n) begin
    assume (lanes_out_valid == $past(lanes_valid));
    assume (!serial_busy || $past(serial_busy) || $past(emit_group));
  end

  always_ff @(posedge clk) if (past_valid && $past(rst_n) && rst_n) begin
    if ($past(done)) assert (!done);                 // one pulse per job
    assert (busy == (st_q != S_IDLE));
    if ($past(busy) && !$past(done)) assert (busy);  // no silent exit
    if (lanes_valid) assert (op_valid);              // never feed garbage
    if (op_ready && !reduce_q) assert (!serial_busy);// no group overrun
    // Every lane result must be accepted by the serialiser, or it is lost.
    if (lanes_out_valid && !reduce_q) assert (!serial_busy);
  end
`endif
endmodule
`default_nettype wire

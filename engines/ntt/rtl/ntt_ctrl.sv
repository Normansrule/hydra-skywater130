/*
 * ntt_ctrl.sv -- the butterfly engine's one controller
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 *   IDLE  waiting
 *   RUN   consume K pair-groups, one per cycle when the source has one
 *   TAIL  let the last group leave the butterfly pipeline
 *   DONE  one completion pulse
 *
 * Refusal, as everywhere else in this chip: a descriptor this engine cannot
 * execute completes immediately with a reason, because silence strands the
 * dispatcher's tag and wedges the machine.
 */
`default_nettype none
module ntt_ctrl
  import ntt_pkg::*;
(
  input  wire            clk,
  input  wire            rst_n,
  input  wire            start,
  input  wire [CNTW-1:0] dim_k,            // groups of NLANE pairs
  input  wire            opclass_ok,
  input  wire            dtype_ok,
  output logic           op_ready,
  input  wire            op_valid,
  output logic           lanes_valid,
  input  wire            lanes_out_valid,
  output logic           done,
  output ntt_status_e    status,
  output logic           busy
);
  typedef enum logic [1:0] {S_IDLE, S_RUN, S_TAIL, S_DONE} state_e;

  state_e          st_q;
  logic [CNTW-1:0] k_left_q;
  ntt_status_e     status_q;

  wire dims_ok = (dim_k != 0);
  wire job_ok  = opclass_ok && dtype_ok && dims_ok;
  wire [1:0] why = !opclass_ok ? NTT_BAD_OPCLASS :
                   !dtype_ok   ? NTT_BAD_DTYPE   : NTT_BAD_DIMS;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= S_IDLE; k_left_q <= '0; status_q <= NTT_OK;
    end else begin
      unique case (st_q)
        S_IDLE: if (start) begin
          if (job_ok) begin
            st_q <= S_RUN; k_left_q <= dim_k; status_q <= NTT_OK;
          end else begin
            st_q <= S_DONE; status_q <= ntt_status_e'(why);
          end
        end
        S_RUN: if (op_valid) begin
          if (k_left_q == CNTW'(1)) st_q <= S_TAIL;
          k_left_q <= k_left_q - CNTW'(1);
        end
        // One pipeline stage, so TAIL is exactly one cycle: the last
        // group's results appear while the controller sits here, and the
        // completion follows them. Waiting for lanes_out_valid to fall
        // instead added a spare cycle -- mutation testing removed the wait
        // and nothing failed, which is how spare cycles get noticed.
        // Completing in RUN, on the other hand, reports a tag free with a
        // result still inside the butterfly registers; the mutation
        // "TAIL skipped entirely" covers that.
        S_TAIL: st_q <= S_DONE;
        S_DONE: st_q <= S_IDLE;
        default: st_q <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    op_ready    = (st_q == S_RUN);
    lanes_valid = (st_q == S_RUN) && op_valid;
    done        = (st_q == S_DONE);
    status      = status_q;
    busy        = (st_q != S_IDLE);
  end

`ifdef FORMAL
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;

  // lanes_out_valid is an input here; this is ntt_lanes' contract.
  always_ff @(posedge clk) if (past_valid && $past(rst_n) && rst_n)
    assume (lanes_out_valid == $past(lanes_valid));

  always_ff @(posedge clk) if (past_valid && $past(rst_n) && rst_n) begin
    if ($past(done)) assert (!done);
    assert (busy == (st_q != S_IDLE));
    if ($past(busy) && !$past(done)) assert (busy);
    if (lanes_valid) assert (op_valid);
    // A completion never coincides with a result still leaving the lanes.
    if (done) assert (!lanes_out_valid);
  end
`endif
endmodule
`default_nettype wire

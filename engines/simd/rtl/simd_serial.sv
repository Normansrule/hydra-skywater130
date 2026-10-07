/*
 * simd_serial.sv -- NLANE results per group onto one 32-bit result port
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * The lanes produce N results at once; the result port carries one. Rather
 * than widen the port to N*32 bits for the whole chip, the group is held
 * here and shifted out over N cycles, and `busy` back-pressures the
 * controller so the next group waits. Same shape as the TPU's drain, on
 * purpose: two engines with the same result-port behaviour are two engines
 * a system integrator only has to understand once.
 */
`default_nettype none
module simd_serial
  import simd_pkg::*;
#(
  parameter int unsigned N = NLANE
) (
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire                    in_valid,
  input  wire  [N*EW-1:0]        y,
  input  wire                    in_last,
  output logic                   res_valid,
  output logic signed [EW-1:0]   res_data,
  output logic                   res_last,
  output logic                   busy
);
  logic [N*EW-1:0]        buf_q;
  logic [$clog2(N+1)-1:0] idx_q;
  logic                   last_q, active_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buf_q <= '0; idx_q <= '0; last_q <= 1'b0; active_q <= 1'b0;
    end else if (in_valid && !active_q) begin
      buf_q <= y; idx_q <= '0; last_q <= in_last; active_q <= 1'b1;
    end else if (active_q) begin
      if (idx_q == ($clog2(N+1))'(N - 1)) active_q <= 1'b0;
      else                                 idx_q <= idx_q + 1'b1;
    end
  end

  assign res_valid = active_q;
  assign res_data  = signed'(buf_q[idx_q*EW +: EW]);
  assign res_last  = active_q && last_q && (idx_q == ($clog2(N+1))'(N - 1));
  assign busy      = active_q;
endmodule
`default_nettype wire

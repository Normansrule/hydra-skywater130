/*
 * ntt_modmul.sv -- (a * b) mod q by Barrett reduction
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Barrett rather than Montgomery: Montgomery is cheaper per multiply but
 * needs every operand carried in a transformed domain, which means the
 * conversion has to happen somewhere and "somewhere" is software. Barrett
 * takes the operands as they are, which keeps the engine's contract to
 * "integers mod q in, integers mod q out" -- the contract the model checks.
 *
 *   t = a*b                      28 bits
 *   u = (t * BM) >> BSH          estimate of t/q, never more than 1 low
 *   r = t - u*q                  in [0, 2q)
 *   r = (r >= q) ? r - q : r     one conditional subtract closes it
 *
 * The single conditional subtract is sufficient only because BM is
 * floor(2^28/q) and t < 2^28; the model asserts the bound on every vector
 * rather than trusting the algebra.
 */
`default_nettype none
module ntt_modmul
  import ntt_pkg::*;
(
  input  wire  [QW-1:0]        a,
  input  wire  [QW-1:0]        b,
  output logic [QW-1:0]        y
);
  wire [2*QW-1:0]     t  = a * b;                    // 2*QW bits
  // The estimate needs the full product of t and the Barrett constant:
  // 2*QW + BMW bits. A fixed 16-bit slice of BM was enough at q = 12289 and
  // truncates the constant at q = 8380417, where BM is 24 bits.
  wire [3*QW:0]       tm = t * BM[BMW-1:0];
  wire [2*QW-1:0]     u  = tm >> BSH;
  wire [2*QW-1:0]  r  = t - (u * Q[QW:0]);
  assign y = (r >= Q[QW:0]) ? (r - Q[QW:0]) : r[QW-1:0];
endmodule
`default_nettype wire

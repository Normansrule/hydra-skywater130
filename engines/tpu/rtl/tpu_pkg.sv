/*
 * tpu_pkg.sv -- HYDRA-130 TPU: shared types and sizes
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * One package so a width changes in one place and the compiler finds every
 * module that needed updating, exactly as mom_pkg.sv does for the dispatcher.
 *
 * The array is OUTPUT-STATIONARY: each processing element owns one element of
 * the result and accumulates into it while operands flow past. That choice is
 * what makes the engine cheap -- no partial sums move during compute, so the
 * only wide bus is the drain path, and the drain happens once per tile.
 */
`default_nettype none
package tpu_pkg;
  localparam int unsigned N_PE  = 4;    // array edge; 16 for the sky130 chip
  localparam int unsigned AW    = 8;    // operand width, INT8
  localparam int unsigned ACCW  = 32;   // accumulator width
  localparam int unsigned KW    = 16;   // K counter width, matches dim_k

  // Status returned with a completion.
  typedef enum logic [1:0] {
    TPU_OK          = 2'd0,
    TPU_BAD_OPCLASS = 2'd1,   // not a GEMM
    TPU_BAD_DTYPE   = 2'd2,   // not INT8
    TPU_BAD_DIMS    = 2'd3    // M or N larger than the array, or K = 0
  } tpu_status_e;
endpackage
`default_nettype wire

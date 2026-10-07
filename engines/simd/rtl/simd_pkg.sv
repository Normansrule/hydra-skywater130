/*
 * simd_pkg.sv -- HYDRA-130 SIMD unit: types, widths and the lane opcode
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHERE THE LANE OPCODE LIVES, AND WHY THAT IS A DECISION
 * ===========================================================================
 * The work descriptor says op_class and dtype; it has no field for "which
 * arithmetic operation". For the TPU that did not matter -- a GEMM is a
 * GEMM. A vector unit needs to know add from multiply from maximum.
 *
 * There are 35 reserved bits at the bottom of the descriptor. This engine
 * reads its opcode from reserved[2:0], i.e. wd[2:0]. That is a real
 * commitment and it is written down here rather than buried in a decoder:
 *
 *   - the dispatcher ignores reserved bits, so nothing upstream changes;
 *   - any future use of wd[2:0] for something else collides with this, and
 *     the collision would be silent -- a vector add quietly becoming a
 *     maximum. If reserved is ever allocated, this moves, and the test
 *     simd_op_field_is_reserved_bits_2_0 in tb_simd fails until it does.
 *
 * The alternative -- a control register holding the opcode -- was rejected
 * because it makes two dispatches with different operations race through a
 * pipelined dispatcher.
 */
`default_nettype none
package simd_pkg;
  localparam int unsigned NLANE = 4;     // lanes
  localparam int unsigned EW    = 32;    // element width
  localparam int unsigned CNTW  = 16;    // group counter, matches dim_k

  // Lane operation, from descriptor bits [2:0].
  typedef enum logic [2:0] {
    SOP_ADD = 3'd0,
    SOP_SUB = 3'd1,
    SOP_MUL = 3'd2,   // low 32 bits of the signed product
    SOP_MAX = 3'd3,   // signed
    SOP_MIN = 3'd4,   // signed
    SOP_AND = 3'd5,
    SOP_OR  = 3'd6,
    SOP_XOR = 3'd7
  } simd_op_e;

  typedef enum logic [1:0] {
    SIMD_OK          = 2'd0,
    SIMD_BAD_OPCLASS = 2'd1,
    SIMD_BAD_DTYPE   = 2'd2,
    SIMD_BAD_DIMS    = 2'd3
  } simd_status_e;
endpackage
`default_nettype wire

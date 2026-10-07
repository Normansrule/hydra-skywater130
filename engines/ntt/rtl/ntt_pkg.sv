/*
 * ntt_pkg.sv -- HYDRA-130 number-theoretic transform: field and widths
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * THE FIELD IS A BUILD OPTION
 * ===========================================================================
 * q = 12289 was the original default. It is the modulus of Falcon and
 * NewHope -- NOT of the post-quantum schemes that were standardised:
 *
 *   ML-KEM (Kyber)      q = 3329       12 bits, product 24
 *   ML-DSA (Dilithium)  q = 8380417    23 bits, product 46
 *   Falcon / NewHope    q = 12289      14 bits, product 28   (default)
 *
 * Caliptra 2.x accelerates ML-DSA and ML-KEM in its Adams Bridge block, so
 * anything here meant to sit beside that work wants one of the first two.
 * Choose with a MACRO, decided before conversion, for the reason written in
 * mom_top.sv: a parameter override is resolved away by sv2v using the
 * DEFAULT, and the override is silently ignored.
 *
 *   sv2v --define=HYDRA_NTT_Q=3329 ...
 *
 * Everything below is derived: width, the Barrett shift and the Barrett
 * constant. The model recomputes all three independently and asserts the
 * reduction bound on every vector, so a modulus that breaks the single
 * conditional subtract fails in Python before it reaches hardware.
 *
 * ===========================================================================
 * WHAT THIS ENGINE IS, AND WHAT IT IS NOT
 * ===========================================================================
 * It is a STREAMING BUTTERFLY ENGINE: coefficient pairs and their twiddle
 * factor go in, the two outputs come back, NLANE pairs at a time. One pass
 * over the data is one stage of the transform.
 *
 * It is NOT a complete transform. A full NTT over n coefficients is log2(n)
 * passes with a different pairing each time, and the addressing that
 * produces those pairings belongs in the direct memory access engine, next
 * to the memory it reads. Building an address generator inside this module
 * would hide the transform's memory behaviour from the dispatcher's cost
 * model, which is the one thing the model has to be able to see.
 *
 * Stated plainly so nobody reads "NTT engine" and expects a transform.
 */
`default_nettype none

`ifndef HYDRA_NTT_Q
  `define HYDRA_NTT_Q 12289
`endif

package ntt_pkg;
  localparam longint unsigned Q_L = `HYDRA_NTT_Q;
  localparam int unsigned Q     = int'(Q_L);
  localparam int unsigned QW    = $clog2(Q_L + 1);   // bits in q
  localparam int unsigned NLANE = 4;          // butterflies in parallel
  localparam int unsigned CNTW  = 16;

  // Barrett constant: floor(2^28 / q). Computed here, checked by the model.
  localparam int unsigned BSH   = 2 * QW;
  // 64-bit intermediate: at q = 8380417 the shift is 46 and a 32-bit
  // computation of this constant silently returns zero.
  localparam longint unsigned BM_L = (64'd1 << BSH) / Q_L;
  localparam int unsigned BMW   = QW + 1;            // bits in BM, always QW+1
  localparam int unsigned BM    = int'(BM_L);        // checked by the model

  typedef enum logic [1:0] {
    NTT_OK          = 2'd0,
    NTT_BAD_OPCLASS = 2'd1,
    NTT_BAD_DTYPE   = 2'd2,
    NTT_BAD_DIMS    = 2'd3
  } ntt_status_e;
endpackage
`default_nettype wire

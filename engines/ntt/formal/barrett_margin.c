/*
 * barrett_margin.c -- how much room ntt_modmul's single conditional subtract has
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * The arithmetic of engines/ntt/rtl/ntt_modmul.sv with the constants of ntt_pkg.sv, swept exhaustively: the
 * largest remainder r = t - ((t*BM) >> BSH)*q before the subtract, for the shipped BM and for the mutation BM-1
 * that mutate_ntt.py keeps as known-equivalent. One subtract is enough while r < 2q.
 *
 *   cc -O2 engines/ntt/formal/barrett_margin.c -o /tmp/barrett_margin && /tmp/barrett_margin
 *
 * q = 8380417 has 7e13 residue pairs and is not swept; its correctness rests on ntt_model.py's per-vector bound.
 */
#include <stdio.h>
#include <stdint.h>

static unsigned clog2(uint64_t v) { unsigned n = 0; while ((1ull << n) < v) n++; return n; }

int main(void) {
  const uint64_t qs[] = {12289, 3329};
  for (unsigned i = 0; i < sizeof qs / sizeof qs[0]; i++) {
    const uint64_t q = qs[i];
    const unsigned qw = clog2(q + 1), bsh = 2 * qw;          /* QW = $clog2(q + 1), BSH = 2*QW */
    const uint64_t bm0 = (1ull << bsh) / q;                    /* BM = floor(2^BSH / q) */
    for (uint64_t bm = bm0; bm + 1 >= bm0; bm--) {
      uint64_t pairs = 0, range = 0;
      for (uint64_t a = 0; a < q; a++)
        for (uint64_t b = 0; b < q; b++) {
          const uint64_t t = a * b, r = t - ((t * bm) >> bsh) * q;
          if (r > pairs) pairs = r;
        }
      for (uint64_t t = 0; t <= (q - 1) * (q - 1); t++) {
        const uint64_t r = t - ((t * bm) >> bsh) * q;
        if (r > range) range = r;
      }
      printf("q = %llu, BM = %llu%s: largest remainder %llu over every residue pair, %llu over every t <= (q-1)^2;"
             " 2q = %llu: %s\n", (unsigned long long)q, (unsigned long long)bm, bm == bm0 ? "" : " (BM-1)",
             (unsigned long long)pairs, (unsigned long long)range, (unsigned long long)(2 * q),
             pairs < 2 * q ? "one subtract is enough" : "one subtract is NOT enough");
      if (bm == 0) break;
    }
  }
  return 0;
}

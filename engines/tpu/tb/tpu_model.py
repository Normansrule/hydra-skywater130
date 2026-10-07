#!/usr/bin/env python3
"""
tpu_model.py -- what the TPU must compute, written from the contract.

Independent of the RTL on purpose: this is plain integer arithmetic over the
same operands, so a disagreement means the hardware is wrong (or the contract
is, which is also worth knowing). It writes the stimulus and the expected
results as hex files the SystemVerilog bench reads.

  A is M x K int8, B is K x N int8, C = A @ B as int32.
  Slice k of the stream is column k of A and row k of B.
"""
import pathlib
import random
import sys

HERE = pathlib.Path(__file__).resolve().parent


def gemm(a, b, m, n, k):
    return [[sum(a[i][t] * b[t][j] for t in range(k)) for j in range(n)]
            for i in range(m)]


def main(npe=4, cases=40, seed=179):
    rnd = random.Random(seed)
    stim, exp, meta = [], [], []
    for c in range(cases):
        m = rnd.randint(1, npe)
        n = rnd.randint(1, npe)
        k = rnd.choice([1, 2, 3, 4, 8, 17, 64])
        # Corner cases first, so a failure reports the simplest one.
        if c == 0:
            m = n = k = 1
        if c == 1:
            m, n, k = npe, npe, 1
        if c == 2:
            m, n, k = npe, npe, 64
        extreme = (c == 3)
        def val():
            return rnd.choice([-128, 127]) if extreme else rnd.randint(-128, 127)
        a = [[val() for _ in range(k)] for _ in range(m)]
        b = [[val() for _ in range(n)] for _ in range(k)]
        c_ref = gemm(a, b, m, n, k)
        meta.append(f"{m} {n} {k}")
        for t in range(k):
            # lanes beyond m or n are zero: the array is N wide regardless
            arow = [a[i][t] if i < m else 0 for i in range(npe)]
            brow = [b[t][j] if j < n else 0 for j in range(npe)]
            stim.append(" ".join(f"{x & 0xFF:02x}" for x in arow + brow))
        for i in range(npe):
            for j in range(npe):
                v = c_ref[i][j] if (i < m and j < n) else 0
                exp.append(f"{v & 0xFFFFFFFF:08x}")
    (HERE / "tpu_stim.hex").write_text("\n".join(stim) + "\n")
    (HERE / "tpu_exp.hex").write_text("\n".join(exp) + "\n")
    (HERE / "tpu_meta.hex").write_text("\n".join(meta) + "\n")
    print(f"tpu_model: {cases} cases, {len(stim)} slices, {len(exp)} results, N={npe}")


if __name__ == "__main__":
    main(npe=int(sys.argv[1]) if len(sys.argv) > 1 else 4)

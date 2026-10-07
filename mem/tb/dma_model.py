#!/usr/bin/env python3
"""
dma_model.py -- operands, layout and expected results for the streamed array.

Writes the two banks in the layout hydra_dma_agen documents (A word k holds
a[0..3][k], B word k holds b[k][0..3]) and the matrix product the hardware
must leave in the C bank. Independent of the RTL: it is the contract, in
Python.
"""
import pathlib, random, sys

HERE = pathlib.Path(__file__).resolve().parent
N = 4


def pack(bytes4):
    v = 0
    for i, b in enumerate(bytes4):
        v |= (b & 0xFF) << (8 * i)
    return v


def main(cases=6, seed=4711):
    # Jobs are placed with a GAP between them. Packed contiguously, the word
    # left on a bank's output after one job (its base plus its length) is
    # exactly the next job's first operand -- so a streamer that skipped the
    # memory-latency wait read a stale word that happened to be right, and
    # the mutation for that bug survived. The gap removes the coincidence.
    rnd = random.Random(seed)
    a_words, b_words, exp, meta = [], [], [], []
    base = 0
    for c in range(cases):
        m = rnd.randint(1, N)
        n = rnd.randint(1, N)
        k = rnd.choice([1, 2, 4, 8, 16]) if c > 1 else [1, 4][c]
        a = [[rnd.randint(-128, 127) for _ in range(k)] for _ in range(m)]
        b = [[rnd.randint(-128, 127) for _ in range(n)] for _ in range(k)]
        # lanes outside the tile are zero: the loader's job, not the engine's
        while len(a_words) < base:            # fill the gap with a poison value
            a_words.append(0xDEADBEEF); b_words.append(0xDEADBEEF)
        for t in range(k):
            a_words.append(pack([a[i][t] if i < m else 0 for i in range(N)]))
            b_words.append(pack([b[t][j] if j < n else 0 for j in range(N)]))
        meta.append(f"{m} {n} {k} {base}")
        for i in range(N):
            for j in range(N):
                v = sum(a[i][t] * b[t][j] for t in range(k)) if (i < m and j < n) else 0
                exp.append(f"{v & 0xFFFFFFFF:08x}")
        base += k + 3          # a gap: see the note at the top of main
    (HERE / "dma_a.hex").write_text("\n".join(f"{w:08x}" for w in a_words) + "\n")
    (HERE / "dma_b.hex").write_text("\n".join(f"{w:08x}" for w in b_words) + "\n")
    (HERE / "dma_exp.hex").write_text("\n".join(exp) + "\n")
    (HERE / "dma_meta.txt").write_text("\n".join(meta) + "\n")
    print(f"dma_model: {cases} jobs, {len(a_words)} slices, {len(exp)} results")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 6)

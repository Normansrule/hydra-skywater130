#!/usr/bin/env python3
"""
dma_simd_model.py -- operands, bank layout and results for the streamed
vector unit.

Bank layout, from hydra_engine_simd_dma's header: a group lives in one
128-bit bank entry, written by four host words at addresses 4g..4g+3, lane
order low to high. The arithmetic is imported from the unit's own model so
there is exactly one definition of what ADD or MAX means.
"""
import pathlib, random, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "engines/simd/tb"))
from simd_model import lane, s32       # one definition, shared

M32 = 0xFFFFFFFF
N = 4


def main(cases=8, seed=8123):
    rnd = random.Random(seed)
    a_words, b_words, exp, meta = [], [], [], []
    base = 0          # in GROUPS; host addresses are 4x this
    for c in range(cases):
        op = c % 8
        reduce_ = (c % 3 == 2)
        k = rnd.choice([1, 2, 4, 8])
        groups = [([rnd.randint(-2**20, 2**20) for _ in range(N)],
                   [rnd.randint(-2**20, 2**20) for _ in range(N)])
                  for _ in range(k)]
        while len(a_words) < base * N:        # poison the gap
            a_words.append(0xDEADBEEF); b_words.append(0xDEADBEEF)
        for (a, b) in groups:
            a_words += [x & M32 for x in a]     # four host words per group
            b_words += [x & M32 for x in b]
        meta.append(f"{op} {1 if reduce_ else 0} {k} {base}")
        if reduce_:
            acc = 0
            for (a, b) in groups:
                acc = s32(acc + sum(lane(op, x, y) for x, y in zip(a, b)))
            exp.append(f"{acc & M32:08x}")
        else:
            for (a, b) in groups:
                for x, y in zip(a, b):
                    exp.append(f"{lane(op, x, y) & M32:08x}")
        base += k + 3          # a gap: see dma_model.py
    (HERE / "dma_simd_a.hex").write_text("\n".join(f"{w:08x}" for w in a_words) + "\n")
    (HERE / "dma_simd_b.hex").write_text("\n".join(f"{w:08x}" for w in b_words) + "\n")
    (HERE / "dma_simd_exp.hex").write_text("\n".join(exp) + "\n")
    (HERE / "dma_simd_meta.txt").write_text("\n".join(meta) + "\n")
    print(f"dma_simd_model: {cases} jobs, {len(a_words)} host words per bank, "
          f"{len(exp)} results")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 8)

#!/usr/bin/env python3
"""
dma_ntt_model.py -- operands, bank layout and results for the streamed
butterfly engine.

Layout, from hydra_engine_ntt_dma's header: four residues per group, one per
16-bit slot, two lanes per host word. The arithmetic is imported from the
engine's own model so there is one definition of the butterfly.
"""
import pathlib, random, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "engines/ntt/tb"))
from ntt_model import butterfly, Q          # one definition, shared

N = 4


def pack2(lo, hi):
    return ((hi & 0xFFFF) << 16) | (lo & 0xFFFF)


def main(cases=6, seed=3407):
    rnd = random.Random(seed)
    aw, bw, ww, exp, meta = [], [], [], [], []
    base = 0
    for c in range(cases):
        k = rnd.choice([1, 2, 4, 8])
        while len(aw) < base * 2:                    # poison the gap
            aw.append(0xDEADBEEF); bw.append(0xDEADBEEF); ww.append(0xDEADBEEF)
        for g in range(k):
            a = [rnd.randrange(Q) for _ in range(N)]
            b = [rnd.randrange(Q) for _ in range(N)]
            w = [rnd.randrange(Q) for _ in range(N)]
            aw.append(pack2(a[0], a[1])); aw.append(pack2(a[2], a[3]))
            bw.append(pack2(b[0], b[1])); bw.append(pack2(b[2], b[3]))
            ww.append(pack2(w[0], w[1])); ww.append(pack2(w[2], w[3]))
            for l in range(N):
                y0, y1 = butterfly(a[l], b[l], w[l])
                exp.append(pack2(y0, y1))
        meta.append(f"{k} {base}")
        base += k + 2                                # gap between jobs
    for n, v in (("a", aw), ("b", bw), ("w", ww)):
        (HERE / f"dma_ntt_{n}.hex").write_text("\n".join(f"{x:08x}" for x in v) + "\n")
    (HERE / "dma_ntt_exp.hex").write_text("\n".join(f"{x:08x}" for x in exp) + "\n")
    (HERE / "dma_ntt_meta.txt").write_text("\n".join(meta) + "\n")
    print(f"dma_ntt_model: {cases} jobs, {len(aw)} host words per bank, "
          f"{len(exp)} butterflies")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 6)

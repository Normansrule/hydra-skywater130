#!/usr/bin/env python3
"""
dma_ntt_model.py -- jobs, operands and expected results for the streamed
butterfly engine, in MEMORY FORMAT v1 (hydra_engine_ntt_dma.sv's header):
one residue per 32-bit host word; operands at group*4 + lane; results at
group*8 + 2*lane (y0) and + 1 (y1). Descriptor bases are group indices.

The arithmetic is imported from the engine's own model, so there is one
definition of the butterfly, at whatever modulus HYDRA_NTT_Q selects.

Output, for tb_hydra_dma_ntt.sv:
  dma_ntt_jobs.txt   one line per job:  kind groups base_a base_b base_c status
                     kind 0 = run and check every result
                          1 = must be refused for range, writing nothing
                          2 = must be refused by the core (wrong class)
  dma_ntt_data.hex   for each kind-0 job in order: A, B, W words
                     (groups*4 each), then the expected C words (groups*8)
  dma_ntt_meta.txt   q, bank depth in groups, total word count

The jobs hit the edges listed in audit R2/R3 (2026-10-11): residues 0 and
q-1, the last legal groups, one group past the end of C and of A, the
longest job the banks hold, all three bases equal (legal: separate banks),
and a descriptor the core refuses.
"""
import pathlib, random, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "engines/ntt/tb"))
from ntt_model import butterfly, Q          # one definition, shared

N, DEPTH = 4, 256
JS_OK, JS_BAD_OPCLASS, JS_BAD_RANGE = 0, 1, 4


def main(seed=3407):
    rnd = random.Random(seed)
    jobs, data = [], []

    def run(groups, ba, bb, bc, edge=False):
        a = [[rnd.randrange(Q) for _ in range(N)] for _ in range(groups)]
        b = [[rnd.randrange(Q) for _ in range(N)] for _ in range(groups)]
        w = [[rnd.randrange(Q) for _ in range(N)] for _ in range(groups)]
        if edge:                       # the extremes, in the first group
            a[0] = [0, Q - 1, Q - 1, 0]
            b[0] = [Q - 1, 0, Q - 1, 1]
            w[0] = [Q - 1, Q - 1, 1, 0]
        for bank in (a, b, w):
            data.extend(x for g in bank for x in g)
        for g in range(groups):
            for l in range(N):
                data.extend(butterfly(a[g][l], b[g][l], w[g][l]))
        jobs.append((0, groups, ba, bb, bc, JS_OK))

    for c in range(6):                                   # ordinary jobs
        run(rnd.choice([1, 2, 4, 8]), c * 10, c * 10 + 3, c * 9, edge=(c == 0))
    run(4, DEPTH - 4, DEPTH - 4, DEPTH - 4)              # the last legal groups
    jobs.append((1, 4, 0, 0, DEPTH - 3, JS_BAD_RANGE))   # C one group past the end
    jobs.append((1, 4, DEPTH - 3, 0, 0, JS_BAD_RANGE))   # A (and W) one past the end
    jobs.append((2, 4, 0, 0, 0, JS_BAD_OPCLASS))         # the core refuses
    run(3, 40, 40, 40)                                    # all three bases equal
    run(DEPTH, 0, 0, 0)                                   # the longest job there is

    (HERE / "dma_ntt_jobs.txt").write_text("".join(" ".join(map(str, j)) + "\n" for j in jobs))
    (HERE / "dma_ntt_data.hex").write_text("".join(f"{x:08x}\n" for x in data))
    (HERE / "dma_ntt_meta.txt").write_text(f"{Q} {DEPTH} {len(data)}\n")
    print(f"dma_ntt_model: q={Q}, {len(jobs)} jobs, {len(data)} words")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
ntt_model.py -- what the butterfly engine must compute, from the contract.

Plain modular arithmetic over q = 12289. It also CHECKS THE BARRETT BOUND
the hardware relies on: the estimate must never be more than one low, or
the single conditional subtract in ntt_modmul leaves a result >= q and the
whole field breaks quietly. Asserting the bound on every vector is cheaper
than trusting the algebra.
"""
import os, pathlib, random, sys

HERE = pathlib.Path(__file__).resolve().parent

# The modulus is a build option; the model must be told the same one the RTL
# was converted with, or it will disagree for a reason that has nothing to do
# with the hardware. Everything else is DERIVED here, independently of the
# package, so a mistake in either is a disagreement rather than a shared
# assumption.
#
#   HYDRA_NTT_Q=3329 python3 ntt_model.py       ML-KEM
#   HYDRA_NTT_Q=8380417 python3 ntt_model.py    ML-DSA
Q = int(os.environ.get("HYDRA_NTT_Q", 12289))
QW = Q.bit_length()
BSH = 2 * QW
BM = (1 << BSH) // Q


def barrett(t):
    u = (t * BM) >> BSH
    r = t - u * Q
    assert 0 <= r < 2 * Q, (
        f"Barrett estimate off by more than one at q={Q} for t={t}: r={r}. "
        f"The single conditional subtract in ntt_modmul cannot close this; "
        f"this modulus needs a wider shift or a second subtract.")
    return r - Q if r >= Q else r


def butterfly(a, b, w):
    v = barrett(b * w)
    return (a + v) % Q, (a - v) % Q


def main(nlane=4, cases=32, seed=6151):
    rnd = random.Random(seed)
    stim, exp, meta = [], [], []
    # exhaustive-ish corners first: zero, one, q-1 in every position
    corners = [(0, 0, 0), (1, 1, 1), (Q - 1, Q - 1, Q - 1), (0, Q - 1, 1),
               (Q - 1, 1, Q - 1), (1, Q - 1, Q - 1)]
    for c in range(cases):
        k = rnd.choice([1, 2, 3, 8]) if c > 2 else [1, 1, 2][c]
        meta.append(str(k))
        for g in range(k):
            a = []
            b = []
            w = []
            for l in range(nlane):
                if corners:
                    ca, cb, cw = corners.pop()
                else:
                    ca, cb, cw = (rnd.randrange(Q), rnd.randrange(Q), rnd.randrange(Q))
                a.append(ca); b.append(cb); w.append(cw)
            # Eight hex digits regardless of q: at q = 8380417 a residue is 23
            # bits and four digits silently truncate it, which reaches the
            # bench as an X rather than as a wrong number.
            stim.append(" ".join(f"{x:08x}" for x in a + b + w))
            for l in range(nlane):
                y0, y1 = butterfly(a[l], b[l], w[l])
                exp.append(f"{y0:08x} {y1:08x}")
    (HERE / "ntt_stim.hex").write_text("\n".join(stim) + "\n")
    (HERE / "ntt_exp.hex").write_text("\n".join(exp) + "\n")
    (HERE / "ntt_meta.txt").write_text("\n".join(meta) + "\n")
    print(f"ntt_model: q={Q} QW={QW} BSH={BSH} BM={BM}, {cases} cases, {len(stim)} groups, "
          f"{len(exp)} butterflies, Barrett bound held on all of them")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 4)

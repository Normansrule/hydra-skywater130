#!/usr/bin/env python3
"""
simd_model.py -- what the SIMD unit must compute, from the contract.

Plain Python over the same operands: elementwise for ELEMENT and SCALAR,
sum-of-lanes-across-groups for REDUCE, all wrapping at 32 bits because the
hardware does and hiding that would make the comparison a lie.
"""
import pathlib, random, sys

HERE = pathlib.Path(__file__).resolve().parent
M32 = 0xFFFFFFFF
OPS = ["ADD", "SUB", "MUL", "MAX", "MIN", "AND", "OR", "XOR"]


def s32(x):
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def lane(op, a, b):
    if op == 0: return s32(a + b)
    if op == 1: return s32(a - b)
    if op == 2: return s32(a * b)
    if op == 3: return a if a > b else b
    if op == 4: return a if a < b else b
    if op == 5: return s32((a & M32) & (b & M32))
    if op == 6: return s32((a & M32) | (b & M32))
    return s32((a & M32) ^ (b & M32))


def main(nlane=4, cases=48, seed=1793):
    rnd = random.Random(seed)
    stim, exp, meta = [], [], []
    for c in range(cases):
        op = c % 8 if c < 16 else rnd.randrange(8)
        reduce_ = (c % 3 == 2)
        k = rnd.choice([1, 2, 3, 7, 16]) if c > 3 else [1, 1, 2, 5][c]
        extreme = (c % 11 == 4)
        def val():
            if extreme:
                return rnd.choice([-2**31, 2**31 - 1, -1, 0, 1])
            return rnd.randint(-2**20, 2**20)
        groups = [([val() for _ in range(nlane)], [val() for _ in range(nlane)])
                  for _ in range(k)]
        meta.append(f"{op} {1 if reduce_ else 0} {k}")
        for (a, b) in groups:
            stim.append(" ".join(f"{x & M32:08x}" for x in a + b))
        if reduce_:
            acc = 0
            for (a, b) in groups:
                acc = s32(acc + sum(lane(op, x, y) for x, y in zip(a, b)))
            exp.append(f"{acc & M32:08x}")
        else:
            for (a, b) in groups:
                for x, y in zip(a, b):
                    exp.append(f"{lane(op, x, y) & M32:08x}")
    (HERE / "simd_stim.hex").write_text("\n".join(stim) + "\n")
    (HERE / "simd_exp.hex").write_text("\n".join(exp) + "\n")
    (HERE / "simd_meta.txt").write_text("\n".join(meta) + "\n")
    print(f"simd_model: {cases} cases, {len(stim)} groups, {len(exp)} results")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 4)

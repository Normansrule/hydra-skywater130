#!/usr/bin/env python3
"""simd_pattern_model.py -- expected checksum for the on-board vector unit."""
import sys
M32 = 0xFFFFFFFF
sys.path.insert(0, "engines/simd/tb")
from simd_model import lane, s32   # one definition of the arithmetic, shared


def job(op, reduce_, k, n=4):
    out = []
    acc = 0
    for g in range(k):
        a = [s32((0x01010101 * (l + 1) + g) & M32) for l in range(n)]
        b = [s32((0x00010001 * (l + 2) + (g << 3)) & M32) for l in range(n)]
        vals = [lane(op, x, y) for x, y in zip(a, b)]
        if reduce_:
            acc = s32(acc + sum(vals))
        else:
            out += vals
    return [acc] if reduce_ else out


def main():
    # k groups = 4k elements; short vectors belong on the scalar core
    jobs = [(0, 0, 8), (2, 0, 16), (7, 1, 32), (3, 0, 12), (0, 1, 64)]
    c = 0
    lines = []
    for (op, red, k) in jobs:
        for v in job(op, red, k):
            c = (((c << 1) | (c >> 31)) & M32) ^ (v & M32)
        lines.append(f"{op} {red} {k} {c:08x}")
    print("\n".join(lines))
    open("sys/tb/simd_pattern_exp.txt", "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
tpu_pattern_model.py -- what the on-board TPU must produce.

Reproduces hydra_engine_tpu's operand pattern and the checksum it keeps, so
the hardware can be checked without reading N*N results over a 4-wire bus.
Written from the adapter's contract, not from its RTL.

    a[i][k] = ((3i + 5k) & 15) - 8
    b[k][j] = ((7j + 11k) & 15) - 8
    checksum = for each result, in row-major order:
                   checksum = rotate_left(checksum, 1) XOR result
"""
import sys

MASK = 0xFFFFFFFF


def tile(n, m, nn, k):
    # lanes outside the tile are zero, as the adapter masks them
    a = [[(((3 * i + 5 * t) & 15) - 8) if i < m else 0 for t in range(k)]
         for i in range(n)]
    b = [[(((7 * j + 11 * t) & 15) - 8) if j < nn else 0 for j in range(n)]
         for t in range(k)]
    out = []
    for i in range(n):
        for j in range(n):
            if i < m and j < nn:
                out.append(sum(a[i][t] * b[t][j] for t in range(k)) & MASK)
            else:
                out.append(0)
    return out


def checksum(values, start=0):
    c = start
    for v in values:
        c = (((c << 1) | (c >> 31)) & MASK) ^ (v & MASK)
    return c


def main(n=4):
    # shapes the retuned cost model actually sends to a 4x4 array
    jobs = [(4, 4, 4), (4, 4, 8), (2, 3, 5), (4, 4, 16), (4, 4, 64)]
    c = 0
    lines = []
    for (m, nn, k) in jobs:
        c = checksum(tile(n, m, nn, k), c)
        lines.append(f"{m} {nn} {k} {c:08x}")
    print("\n".join(lines))
    with open("sys/tb/tpu_pattern_exp.txt", "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 4)

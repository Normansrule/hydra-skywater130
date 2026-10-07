#!/usr/bin/env python3
"""
xsec_model.py -- reference semantics for the security instructions.

Written from the ratified specification's execute clauses (Zknh) and from
the Xhydrasec table in docs/ISA_SECURITY.md, not from the RTL.

The four SHA-256 helpers are ALSO checked against hashlib before any vector
is written: a full SHA-256 compression is computed with these functions and
compared with hashlib's digest. If the model's own rotation amounts were
wrong, that check fails here, in Python, before it can agree with a wrong
piece of hardware.
"""
import hashlib, pathlib, random, struct

HERE = pathlib.Path(__file__).resolve().parent
M32, M64 = (1 << 32) - 1, (1 << 64) - 1


def ror(x, n):
    return ((x >> n) | (x << (32 - n))) & M32


def sum0(x): return ror(x, 2) ^ ror(x, 13) ^ ror(x, 22)
def sum1(x): return ror(x, 6) ^ ror(x, 11) ^ ror(x, 25)
def sig0(x): return ror(x, 7) ^ ror(x, 18) ^ (x >> 3)
def sig1(x): return ror(x, 17) ^ ror(x, 19) ^ (x >> 10)


def sext32(v):
    return (v | (M64 ^ M32)) if (v >> 31) & 1 else v


# ---- encodings, from the official riscv-opcodes table -----------------------
def zknh(sub, rd, rs1):
    return (0b0001000 << 25) | (sub << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0x13


def hsec(f3, rd=0, rs1=0, rs2=0):
    return (0 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0b0001011


# ---- the helpers must reproduce a real SHA-256 --------------------------------
K = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
     0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
     0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
     0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
     0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
     0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
     0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
     0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]


def sha256_via_helpers(msg):
    h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    p = msg + b"\x80"
    while len(p) % 64 != 56:
        p += b"\x00"
    p += (len(msg) * 8).to_bytes(8, "big")
    for off in range(0, len(p), 64):
        w = list(struct.unpack(">16I", p[off:off + 64]))
        for t in range(16, 64):
            w.append((sig1(w[t - 2]) + w[t - 7] + sig0(w[t - 15]) + w[t - 16]) & M32)
        a, b, c, d, e, f, g, hh = h
        for t in range(64):
            t1 = (hh + sum1(e) + ((e & f) ^ (~e & g)) + K[t] + w[t]) & M32
            t2 = (sum0(a) + ((a & b) ^ (a & c) ^ (b & c))) & M32
            hh, g, f, e, d, c, b, a = g, f, e, (d + t1) & M32, c, b, a, (t1 + t2) & M32
        h = [(x + y) & M32 for x, y in zip(h, [a, b, c, d, e, f, g, hh])]
    return b"".join(x.to_bytes(4, "big") for x in h)


def main():
    for m in (b"", b"abc", bytes(range(200))):
        assert sha256_via_helpers(m) == hashlib.sha256(m).digest(), \
            "the model's SHA-256 helpers disagree with hashlib -- fix the model first"
    print("xsec_model: helper functions reproduce hashlib on 3 messages")

    rnd = random.Random(20260928)
    vecs = []
    fns = [sum0, sum1, sig0, sig1]
    specials = [0, M64, 0x80000000, 0x7FFFFFFF, 0xFFFFFFFF_00000000, 0x00000000_FFFFFFFF]
    for sub in range(4):
        for v in specials + [rnd.getrandbits(64) for _ in range(40)]:
            # Upper 32 bits of rs1 are IGNORED, and the result is sign-extended:
            # both halves of that rule are exercised by the specials above.
            vecs.append((zknh(sub, 5, 6), v, 0, 3, 1, sext32(fns[sub](v & M32)), 0))

    for _ in range(40):
        a = rnd.getrandbits(64)
        b = a if rnd.random() < 0.5 else a ^ (1 << rnd.randrange(64))
        vecs.append((hsec(0b110, rd=5, rs1=6, rs2=7), a, b, 0, 1, int(a == b), 0))

    # privilege: kvwrite / kvlock trap outside machine mode, succeed inside
    for priv in (0, 1, 3):
        for f3 in (0b001, 0b010):
            vecs.append((hsec(f3, rs1=6, rs2=7), rnd.getrandbits(64), rnd.getrandbits(64),
                         priv, 0, 0, 0 if priv == 3 else 1))
    vecs.append((hsec(0b111, rd=5), 0, 0, 3, 0, 0, 1))          # reserved: illegal

    (HERE / "xsec_vectors.txt").write_text(
        "\n".join(f"{i:08x} {a:016x} {b:016x} {p} {we} {r:016x} {ill}"
                  for i, a, b, p, we, r, ill in vecs) + "\n")
    print(f"xsec_model: {len(vecs)} vectors")


if __name__ == "__main__":
    main()

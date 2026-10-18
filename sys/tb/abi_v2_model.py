#!/usr/bin/env python3
"""abi_v2_model.py -- independent model of descriptor ABI version 2's checks.

Written from the table in docs/architecture/heterogeneous-system.md and the
header layout in sys/rtl/hydra_abi_v2.sv's comment, not from the RTL body.
Writes a vector file for sys/tb/tb_abi_v2.sv:

  W <ctx_id> <owned> <epoch>                       a context-table write
  J <hdr:16 hex> <tag> <healthy> <code> <mask>     a job and what must happen

  python3 sys/tb/abi_v2_model.py <out file> [cases] [seed]
"""
import random, sys

NENG, NCTX, PRESENT = 6, 16, 0b111111
SLOT = {1: 0, 2: 5, 3: 2, 4: 1, 5: 3}            # policy -> engine slot (CPU, GPU, TPU, SIMD, NTT)
OK, VERSION, RESERVED, MODE, POLICY, CONTEXT, KEY, NO_ENGINE = range(8)


def header(ver, mode, pol, ctx, epoch, key, prof, rsvd):
    return (ver << 60) | (mode << 58) | (pol << 55) | (ctx << 47) | (epoch << 31) | (key << 23) | (prof << 15) | rsvd


def verdict(f, table, healthy):
    if f["ver"] != 2: return VERSION, 0
    if f["rsvd"]: return RESERVED, 0
    if f["mode"] != 0: return MODE, 0
    if f["pol"] > 5: return POLICY, 0
    if not (f["ctx"] < NCTX and table[f["ctx"]][0] and table[f["ctx"]][1] == f["epoch"]): return CONTEXT, 0
    if f["key"] or f["prof"]: return KEY, 0
    want = (1 << NENG) - 1 if f["pol"] == 0 else 1 << SLOT[f["pol"]]
    mask = want & PRESENT & healthy
    return (NO_ENGINE, 0) if mask == 0 else (OK, mask)


def main():
    out = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
    rnd = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 2026)
    table = [[0, 0] for _ in range(NCTX)]
    lines, counts = [], [0] * 8
    for i in range(n):
        if rnd.random() < 0.15:                                   # change a context
            c = rnd.randrange(NCTX); o = rnd.random() < 0.8; e = rnd.randrange(4)
            table[c] = [int(o), e]
            lines.append(f"W {c:x} {int(o)} {e:x}")
            continue
        good = rnd.random() < 0.55                                # mostly near-valid headers
        f = dict(ver=2 if good or rnd.random() < 0.7 else rnd.choice([0, 1, 3, 15]),
                 mode=0 if good or rnd.random() < 0.6 else rnd.randrange(1, 4),
                 pol=rnd.randrange(6) if good or rnd.random() < 0.8 else rnd.choice([6, 7]),
                 ctx=rnd.randrange(NCTX) if rnd.random() < 0.95 else rnd.randrange(NCTX, 256),
                 key=0 if good or rnd.random() < 0.8 else rnd.randrange(1, 256),
                 prof=0 if good or rnd.random() < 0.8 else rnd.randrange(1, 256),
                 rsvd=0 if good or rnd.random() < 0.85 else rnd.randrange(1, 1 << 15))
        c = f["ctx"]
        f["epoch"] = table[c][1] if (c < NCTX and (good or rnd.random() < 0.7)) else rnd.randrange(4)
        healthy = (1 << NENG) - 1 if rnd.random() < 0.7 else rnd.randrange(1 << NENG)
        code, mask = verdict(f, table, healthy)
        counts[code] += 1
        h = header(f["ver"], f["mode"], f["pol"], c, f["epoch"], f["key"], f["prof"], f["rsvd"])
        lines.append(f"J {h:016x} {rnd.randrange(256):02x} {healthy:02x} {code:x} {mask:02x}")
    open(out, "w").write("\n".join(lines) + "\n")
    names = ["ok", "version", "reserved", "mode", "policy", "context", "key", "no_engine"]
    print("abi_v2_model: " + ", ".join(f"{names[k]} {counts[k]}" for k in range(8)))
    if min(counts) == 0:
        sys.exit("abi_v2_model: some outcome never occurs; the vectors would not test it")


if __name__ == "__main__":
    main()

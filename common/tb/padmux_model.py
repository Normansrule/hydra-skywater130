#!/usr/bin/env python3
"""
padmux_model.py -- independent reference model for hydra_padmux.

Written from the CONTRACT in the RTL header, not from the RTL. Emits a vector
file that tb_hydra_padmux.sv replays and compares exactly, every cycle.

Vector line (hex fields, space separated):
  rst_n cfg_we cfg_sel cfg_lock alt_out alt_oe alt_idle pad_in
  exp_sel exp_locked exp_pad_out exp_pad_oe exp_alt_in

Timing convention, matching the testbench:
  1. inputs applied; rst_n low resets state immediately (async assert)
  2. outputs compared
  3. rising edge: state updates (if rst_n high)
"""
import random
import sys

NPAD, NALT, SELW = 5, 3, 2          # NALT not a power of two on purpose
RESET_SEL = [1, 2, 0, 1, 2]         # non-zero, so a reset bug is visible


def pack(vals, w):
    out = 0
    for i, v in enumerate(vals):
        out |= (v & ((1 << w) - 1)) << (i * w)
    return out


def bit(x, i):
    return (x >> i) & 1


class PadMux:
    def __init__(self):
        self.sel = list(RESET_SEL)
        self.locked = 0

    def reset(self):
        self.sel = list(RESET_SEL)
        self.locked = 0

    def outputs(self, rst_n, alt_out, alt_oe, alt_idle, pad_in):
        pad_out = pad_oe = alt_in = 0
        for p in range(NPAD):
            s = self.sel[p]
            pad_out |= bit(alt_out, p * NALT + s) << p
            pad_oe |= (bit(alt_oe, p * NALT + s) & rst_n) << p
            for k in range(NALT):
                v = bit(pad_in, p) if k == s else bit(alt_idle, p * NALT + k)
                alt_in |= v << (p * NALT + k)
        return pad_out, pad_oe, alt_in

    def clock(self, cfg_we, cfg_sel, cfg_lock):
        if cfg_we and not self.locked:
            for p in range(NPAD):
                code = (cfg_sel >> (p * SELW)) & ((1 << SELW) - 1)
                if code < NALT:
                    self.sel[p] = code
        self.locked = self.locked | cfg_lock


def main(path, n, seed):
    rng = random.Random(seed)
    m = PadMux()
    lines = []
    for i in range(n):
        rst_n = 0 if (i < 2 or rng.random() < 0.01) else 1
        cfg_we = int(rng.random() < 0.35)
        cfg_sel = pack([rng.randrange(1 << SELW) for _ in range(NPAD)], SELW)
        cfg_lock = int(rng.random() < 0.004)
        alt_out = rng.getrandbits(NPAD * NALT)
        alt_oe = rng.getrandbits(NPAD * NALT)
        alt_idle = rng.getrandbits(NPAD * NALT)
        pad_in = rng.getrandbits(NPAD)

        if not rst_n:
            m.reset()
        po, poe, ai = m.outputs(rst_n, alt_out, alt_oe, alt_idle, pad_in)
        lines.append(" ".join(f"{v:x}" for v in (
            rst_n, cfg_we, cfg_sel, cfg_lock, alt_out, alt_oe, alt_idle, pad_in,
            pack(m.sel, SELW), m.locked, po, poe, ai)))
        if rst_n:
            m.clock(cfg_we, cfg_sel, cfg_lock)

    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    locks = sum(1 for l in lines if l.split()[9] == "1")
    print(f"padmux_model: {n} vectors, {locks} cycles locked -> {path}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "padmux_vectors.hex",
         int(sys.argv[2]) if len(sys.argv) > 2 else 20000,
         int(sys.argv[3]) if len(sys.argv) > 3 else 1)

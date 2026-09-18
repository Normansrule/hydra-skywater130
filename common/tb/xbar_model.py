#!/usr/bin/env python3
"""
xbar_model.py -- independent reference model for mom_xbar.

Written from the CONTRACT in the RTL header, not from the RTL. Emits vectors
that tb_mom_xbar.sv replays with an exact compare on every output, every
cycle -- including the misbehaving-engine cases the formal proofs assume away.

Line (hex): rst_n disp_valid disp_engine disp_tag eng_ready eng_done eng_done_tag
            | disp_accept eng_valid comp_valid comp_tag eng_busy
              err_bad_engine err_done_unknown
"""
import random
import sys

NENG, NTAG, TAGW, ENGW = 5, 8, 4, 3


class Xbar:
    def __init__(self):
        self.reset()

    def reset(self):
        self.busy = [0] * NENG
        self.pend = [0] * NENG
        self.tag = [0] * NENG
        self.rr = 0
        self.err_bad = 0
        self.err_unk = 0

    def outputs(self, dv, de, dt, ready, done, done_tag):
        in_range = de < NENG
        free = in_range and not self.busy[de] and (ready >> de) & 1
        fwd = dv and free
        bad = dv and not in_range
        eng_valid = (1 << de) if fwd else 0

        done_ok = 0
        for e in range(NENG):
            if (done >> e) & 1 and self.busy[e] and not self.pend[e] \
               and ((done_tag >> (e * TAGW)) & 0xF) == self.tag[e]:
                done_ok |= 1 << e
        done_bad = done & ~done_ok & ((1 << NENG) - 1)

        ready_set = 0
        for e in range(NENG):
            if self.pend[e] or (done_ok >> e) & 1:
                ready_set |= 1 << e
        take_e, take_any = 0, 0
        for i in range(NENG):                     # lowest offset from rr wins
            e = (i + self.rr) % NENG
            if (ready_set >> e) & 1:
                take_any, take_e = 1, e
                break

        return dict(accept=int(fwd or bad), eng_valid=eng_valid,
                    comp_valid=take_any, comp_tag=self.tag[take_e] if take_any else 0,
                    busy=sum(b << i for i, b in enumerate(self.busy)),
                    err_bad=self.err_bad, err_unk=self.err_unk,
                    _fwd=fwd, _de=de, _dt=dt, _done_ok=done_ok,
                    _done_bad=done_bad, _take=(take_any, take_e), _bad=bad)

    def clock(self, o):
        self.err_bad = int(o["_bad"])
        self.err_unk = int(o["_done_bad"] != 0)
        if o["_fwd"]:
            self.busy[o["_de"]] = 1
            self.tag[o["_de"]] = o["_dt"]
        for e in range(NENG):
            if (o["_done_ok"] >> e) & 1:
                self.pend[e] = 1
        take_any, take_e = o["_take"]
        if take_any:
            self.pend[take_e] = 0
            self.busy[take_e] = 0
            self.rr = 0 if take_e == NENG - 1 else take_e + 1


def main(path, n, seed):
    rng = random.Random(seed)
    m = Xbar()
    lines = []
    stats = dict(fwd=0, comp=0, bad=0, unk=0, allbusy=0)
    for i in range(n):
        rst_n = 0 if (i < 2 or rng.random() < 0.004) else 1
        dv = int(rng.random() < 0.45)
        de = rng.randrange(1 << ENGW)              # 5..7 are out of range
        dt = rng.randrange(NTAG)
        ready = rng.getrandbits(NENG) | (0x1F if rng.random() < 0.6 else 0)
        # engines mostly behave; sometimes they lie (wrong tag / not busy)
        done = 0
        for e in range(NENG):
            if m.busy[e] and not m.pend[e] and rng.random() < 0.25:
                done |= 1 << e
        if rng.random() < 0.03:
            done |= 1 << rng.randrange(NENG)       # a lie
        done_tag = 0
        for e in range(NENG):
            t = m.tag[e] if rng.random() < 0.9 else rng.randrange(NTAG)
            done_tag |= (t & 0xF) << (e * TAGW)

        if not rst_n:
            m.reset()
        o = m.outputs(rst_n and dv, de, dt, ready, done if rst_n else 0, done_tag)
        stats["fwd"] += o["_fwd"]
        stats["comp"] += o["comp_valid"]
        stats["bad"] += o["_bad"]
        stats["unk"] += int(o["_done_bad"] != 0)
        stats["allbusy"] += int(o["busy"] == 0x1F)
        lines.append(" ".join(f"{v:x}" for v in (
            rst_n, dv, de, dt, ready, done if rst_n else 0, done_tag,
            o["accept"], o["eng_valid"], o["comp_valid"], o["comp_tag"],
            o["busy"], o["err_bad"], o["err_unk"])))
        if rst_n:
            m.clock(o)

    open(path, "w").write("\n".join(lines) + "\n")
    print(f"xbar_model: {n} vectors -> {path}; {stats}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "xbar_vectors.hex",
         int(sys.argv[2]) if len(sys.argv) > 2 else 20000,
         int(sys.argv[3]) if len(sys.argv) > 3 else 179)

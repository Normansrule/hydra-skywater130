#!/usr/bin/env python3
"""
mutate_simd.py -- break the vector unit on purpose; every break must be caught.
Same contract as mutate_tpu.py: simulation mutations go against tb_simd,
formal ones against simd_ctrl.sby, and a survivor is reported, not ignored.
"""
import pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent          # engines/simd
REPO = ROOT.parent.parent

SIM = [
    ("subtract becomes add", "rtl/simd_alu.sv",
     "SOP_SUB: y = a - b;", "SOP_SUB: y = a + b;"),
    ("multiply keeps the high half", "rtl/simd_alu.sv",
     "SOP_MUL: y = prod[EW-1:0];", "SOP_MUL: y = prod[2*EW-1:EW];"),
    ("maximum compares unsigned", "rtl/simd_alu.sv",
     "SOP_MAX: y = (a > b) ? a : b;",
     "SOP_MAX: y = ($unsigned(a) > $unsigned(b)) ? a : b;"),
    ("reduction misses a lane", "rtl/simd_reduce.sv",
     "for (int l = 0; l < N; l++) lane_sum = lane_sum + signed'(y[l*EW +: EW]);",
     "for (int l = 0; l < N-1; l++) lane_sum = lane_sum + signed'(y[l*EW +: EW]);"),
    ("accumulator not cleared between jobs", "rtl/simd_reduce.sv",
     "else if (clr)         acc <= '0;", "else if (1'b0)        acc <= '0;"),
    ("group accepted while a result is in flight", "rtl/simd_ctrl.sv",
     "(reduce_q || (!serial_busy && !lanes_out_valid));",
     "(reduce_q || !serial_busy);"),
    ("opcode read from the wrong bits", "rtl/simd_top.sv",
     "simd_op_e'(eng_wd[2:0]);", "simd_op_e'(eng_wd[5:3]);"),
]

FORMAL = [
    ("completion held for two cycles", "rtl/simd_ctrl.sv",
     "        S_DONE: st_q <= S_IDLE;", "        S_DONE: st_q <= S_DONE;"),
    ("busy drops without a completion", "rtl/simd_ctrl.sv",
     "busy        = (st_q != S_IDLE);", "busy        = (st_q == S_RUN);"),
    ("lanes fed without an operand", "rtl/simd_ctrl.sv",
     "lanes_valid = (st_q == S_RUN) && op_valid && op_ready;",
     "lanes_valid = (st_q == S_RUN) && op_ready;"),
]


def run(cmd, cwd, timeout=300):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True,
                          text=True, timeout=timeout)


def with_mutation(rel, old, new, body):
    src = ROOT / rel
    orig = src.read_text()
    if orig.count(old) != 1:
        return None, f"anchor not unique ({orig.count(old)}) in {rel}"
    src.write_text(orig.replace(old, new))
    try:
        return body(), None
    finally:
        src.write_text(orig)


def sim_catches():
    c = run("sv2v engines/simd/rtl/*.sv engines/simd/tb/tb_simd.sv > /tmp/msim.v && "
            "iverilog -g2012 -o /tmp/msim /tmp/msim.v && vvp -n /tmp/msim", REPO)
    return "PASS tb_simd" not in c.stdout


def formal_catches():
    c = run("sv2v --define=FORMAL -E Assert rtl/simd_pkg.sv rtl/simd_ctrl.sv "
            "> formal/simd_ctrl_sv2v.v && cd formal && sby -f simd_ctrl.sby prove", ROOT)
    return "DONE (PASS" not in c.stdout


def main():
    killed = survived = 0
    for group, fn, tag in ((SIM, sim_catches, "simulation"),
                           (FORMAL, formal_catches, "formal")):
        for name, rel, old, new in group:
            got, err = with_mutation(rel, old, new, fn)
            if err:
                print(f"SKIP  {name}: {err}"); continue
            print(("KILL  " if got else "ALIVE ") + name + f"  [{tag}]")
            killed += got; survived += not got
    print(f"\n{killed} killed, {survived} survived")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()

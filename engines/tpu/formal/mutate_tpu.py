#!/usr/bin/env python3
"""
mutate_tpu.py -- break the TPU on purpose; every break must be caught.

Simulation mutations go against tb_tpu (the model comparison); formal
mutations go against tpu_ctrl.sby. A mutation that survives is either a
missing test or dead logic, and either way it is reported, never ignored.
"""
import pathlib, re, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent          # engines/tpu
REPO = ROOT.parent.parent

SIM = [
    ("PE drops the accumulate enable",
     "rtl/tpu_pe.sv", "else if (en)        acc_q <= acc_q + ACCW'(prod);",
     "else if (1'b1)      acc_q <= acc_q + ACCW'(prod);"),
    ("feeder advances while stalled",
     "rtl/tpu_feeder.sv", "end else if (step) begin", "end else if (1'b1) begin"),
    ("row order not reversed",
     "rtl/tpu_top.sv", "a_rev[i] = op_a[N-1-i];", "a_rev[i] = op_a[i];"),
    ("flush one cycle short",
     "rtl/tpu_ctrl.sv", "flush_q == ($clog2(2*N))'(2*N - 3)",
     "flush_q == ($clog2(2*N))'(2*N - 4)"),
    ("tail state skipped",
     "rtl/tpu_ctrl.sv", "if (row_q == ($clog2(N+1))'(N - 1)) st_q <= S_TAIL;",
     "if (row_q == ($clog2(N+1))'(N - 1)) st_q <= S_DONE;"),
    # KNOWN SURVIVOR, kept deliberately. Draining shifts zeros in from the
    # top row, so a completed tile leaves the array already cleared and clr
    # changes nothing on the normal path. It matters only for a tile that is
    # abandoned part-way -- a case the engine port cannot currently produce,
    # because the dispatcher never retracts work. Removing clr would save a
    # gate per processing element and lose the only defence if that ever
    # changes. Listed here so the choice is visible, not silently untested.
    ("accumulator not cleared between tiles",
     "rtl/tpu_pe.sv", "if (clr)            acc_q <= '0;",
     "if (1'b0)           acc_q <= '0;"),
]

FORMAL = [
    ("completion held for two cycles",
     "rtl/tpu_ctrl.sv", "        S_DONE: st_q <= S_IDLE;", "        S_DONE: st_q <= S_DONE;"),
    ("ready asserted while busy",
     "rtl/tpu_ctrl.sv", "busy       = (st_q != S_IDLE);", "busy       = (st_q == S_STREAM);"),
    ("drain overlaps the serialiser",
     "rtl/tpu_ctrl.sv", "row_valid  = (st_q == S_DRAIN) && !drain_busy;",
     "row_valid  = (st_q == S_DRAIN);"),
]


def run(cmd, cwd, timeout=300):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True,
                          text=True, timeout=timeout)


def with_mutation(rel, old, new, body):
    src = ROOT / rel
    orig = src.read_text()
    if orig.count(old) != 1:
        return None, f"anchor not unique ({orig.count(old)} matches) in {rel}"
    src.write_text(orig.replace(old, new))
    try:
        return body(), None
    finally:
        src.write_text(orig)


def sim_catches():
    c = run("sv2v engines/tpu/rtl/*.sv engines/tpu/tb/tb_tpu.sv > /tmp/mut.v && "
            "iverilog -g2012 -o /tmp/mut /tmp/mut.v && vvp -n /tmp/mut", REPO)
    return "PASS tb_tpu" not in c.stdout


def formal_catches():
    c = run("sv2v --define=FORMAL -E Assert rtl/tpu_pkg.sv rtl/tpu_ctrl.sv "
            "> formal/tpu_ctrl_sv2v.v && cd formal && sby -f tpu_ctrl.sby prove", ROOT)
    return "DONE (PASS" not in c.stdout


def main():
    killed = survived = 0
    for name, rel, old, new in SIM:
        got, err = with_mutation(rel, old, new, sim_catches)
        if err:
            print(f"SKIP  {name}: {err}"); continue
        print(("KILL  " if got else "ALIVE ") + name + "  [simulation]")
        killed += got; survived += not got
    for name, rel, old, new in FORMAL:
        got, err = with_mutation(rel, old, new, formal_catches)
        if err:
            print(f"SKIP  {name}: {err}"); continue
        print(("KILL  " if got else "ALIVE ") + name + "  [formal]")
        killed += got; survived += not got
    print(f"\n{killed} killed, {survived} survived")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()

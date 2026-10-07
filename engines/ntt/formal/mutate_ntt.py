#!/usr/bin/env python3
"""mutate_ntt.py -- break the butterfly engine; every break must be caught."""
import pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = ROOT.parent.parent

SIM = [
    ("Barrett drops the conditional subtract", "rtl/ntt_modmul.sv",
     "assign y = (r >= Q[QW:0]) ? (r - Q[QW:0]) : r[QW-1:0];",
     "assign y = r[QW-1:0];"),
    # KNOWN-EQUIVALENT AT q = 12289, and only there. With BM-1 the largest
    # intermediate remainder over the whole product range is 22,887, below
    # 2q = 24,578, so the single conditional subtract closes it and the
    # results are identical -- verified by sweep, not by argument.
    #
    # This suite runs at the default modulus. At another q the margin is
    # different and this mutation may well be a real fault, which is the
    # point of the bound assertion in ntt_model.py: it is checked per
    # modulus, on every vector, rather than assumed from this one case.
    ("Barrett constant off by one (equivalent)", "rtl/ntt_pkg.sv",
     "  localparam int unsigned BM    = int'(BM_L);        // checked by the model",
     "  localparam int unsigned BM    = int'(BM_L) - 1;"),
    ("butterfly subtracts without borrowing q", "rtl/ntt_butterfly.sv",
     "wire [QW:0] diff = a + Q[QW:0] - v;", "wire [QW:0] diff = a - v;"),
    ("add skips its reduction", "rtl/ntt_butterfly.sv",
     "y0        <= (sum  >= Q[QW:0]) ? (sum  - Q[QW:0]) : sum[QW-1:0];",
     "y0        <= sum[QW-1:0];"),
    ("twiddle ignored", "rtl/ntt_butterfly.sv",
     "ntt_modmul u_mul (.a(b), .b(w), .y(v));",
     "ntt_modmul u_mul (.a(b), .b(14'd1), .y(v));"),
    ("partial group padded instead of refused", "rtl/ntt_top.sv",
     "wire [CNTW-1:0] wd_groups  = m_aligned ? (wd_m >> $clog2(N)) : '0;",
     "wire [CNTW-1:0] wd_groups  = (wd_m >> $clog2(N));"),
]

FORMAL = [
    ("completion held for two cycles", "rtl/ntt_ctrl.sv",
     "        S_DONE: st_q <= S_IDLE;", "        S_DONE: st_q <= S_DONE;"),
    ("TAIL skipped entirely: completion before the last result", "rtl/ntt_ctrl.sv",
     "          if (k_left_q == CNTW'(1)) st_q <= S_TAIL;",
     "          if (k_left_q == CNTW'(1)) st_q <= S_DONE;"),
    ("lanes fed without an operand", "rtl/ntt_ctrl.sv",
     "lanes_valid = (st_q == S_RUN) && op_valid;",
     "lanes_valid = (st_q == S_RUN);"),
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
    c = run("sv2v engines/ntt/rtl/*.sv engines/ntt/tb/tb_ntt.sv > /tmp/mntt.v && "
            "iverilog -g2012 -o /tmp/mntt /tmp/mntt.v && vvp -n /tmp/mntt", REPO)
    return "PASS tb_ntt" not in c.stdout


def formal_catches():
    c = run("sv2v --define=FORMAL -E Assert rtl/ntt_pkg.sv rtl/ntt_ctrl.sv "
            "> formal/ntt_ctrl_sv2v.v && cd formal && sby -f ntt_ctrl.sby prove", ROOT)
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

#!/usr/bin/env python3
"""
mutate_cost_mux.py -- break the shared cost sequencer; every break must show
up as a DIFFERENT DECISION than the parallel build makes.

The point of tb_cost_trace is that the tile's shipped configuration decides
what the v1-equivalent configuration decides. A comparison that cannot fail
proves nothing, so each mutation here breaks the sweep in a way that should
change some dispatch, and the trace comparison has to notice.

The baseline is checked first: an equivalence test that is already failing
would report every mutation as caught.
"""
import pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RTL = ROOT / "tt/tile/src/rtl/mom_top.sv"

MUTATIONS = [
    ("last engine never evaluated",
     "    wire last = (idx == 3'(ENG_N - 1)) && phase;",
     "    wire last = (idx == 3'(ENG_N - 2)) && phase;"),
    ("results captured a cycle early, before stage B settles",
     "    assign lane_we      = eval_busy && phase;",
     "    assign lane_we      = eval_busy && !phase;"),
    ("calibration factor taken from the next engine's row",
     "      .param(params[idx]), .k_cal(k_cal[idx]),",
     "      .param(params[idx]), .k_cal(k_cal[(idx + 1) % ENG_N]),"),
    ("result written to the wrong lane",
     "    assign lane_idx     = idx;",
     "    assign lane_idx     = (idx == 3'd0) ? 3'd1 : idx;"),
    # KNOWN-EQUIVALENT, kept with its reason rather than deleted. Advancing
    # every cycle re-latches stage A during the second cycle -- with the SAME
    # inputs, because each engine's inputs are held across both of its cycles.
    # The second latch is therefore a no-op. It survives because holding the
    # inputs is exactly what makes it harmless; if the sweep is ever changed
    # to skew the selects and save five cycles, this mutation starts killing
    # and this comment is the warning that it should.
    ("engine advanced every cycle (equivalent while inputs are held)",
     "      .clk(clk), .rst_n(rst_n), .adv(eval_busy && !phase),",
     "      .clk(clk), .rst_n(rst_n), .adv(eval_busy),"),
]


def trace(mode):
    d = "1'b1" if mode == "shared" else "1'b0"
    cmd = (f"sv2v --define=HYDRA_COST_SHARED=\"{d}\" tt/tile/src/rtl/*.sv "
           f"tt/tb/tb_cost_trace.sv > /tmp/mc_{mode}.v && "
           f"iverilog -g2012 -o /tmp/mc_{mode} /tmp/mc_{mode}.v && "
           f"vvp -n /tmp/mc_{mode}")
    r = subprocess.run(cmd, cwd=ROOT, shell=True, capture_output=True,
                       text=True, timeout=300)
    return [l for l in r.stdout.splitlines() if l[:2] in ("D ", "U ", "EN")]


def main():
    base_s, base_p = trace("shared"), trace("parallel")
    if not base_s or base_s != base_p:
        print("BASELINE IS RED: the two builds already disagree. Fix that "
              "before reading any mutation score.")
        sys.exit(2)
    print(f"baseline green: {len(base_s)} identical decision lines\n")

    orig = RTL.read_text()
    killed = survived = 0
    for name, old, new in MUTATIONS:
        if orig.count(old) != 1:
            print(f"SKIP  {name}: anchor not unique ({orig.count(old)})")
            continue
        RTL.write_text(orig.replace(old, new))
        try:
            caught = trace("shared") != base_p
        finally:
            RTL.write_text(orig)
        print(("KILL  " if caught else "ALIVE ") + name)
        killed += caught
        survived += not caught
    print(f"\n{killed} killed, {survived} survived")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()

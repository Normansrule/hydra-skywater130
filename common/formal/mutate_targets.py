#!/usr/bin/env python3
"""
mutate_targets.py -- every property must be able to fail.

WHY THIS FILE IS SHAPED THE WAY IT IS
  Four times in this project (s135 p256_point, s136 ntt_top, s178 core_mini,
  s178m p256_modaddsub) a mutation anchor went stale after a correct edit and
  silently stopped testing anything while the summary still said ALL KILLED.
  So:
    * an anchor is a short DISTINCTIVE fragment, never a whole formatted line;
    * before any run, every anchor must occur EXACTLY ONCE in the pristine
      source -- zero or two matches is a hard failure, not a skip;
    * a run that yields no verdict (timeout, crash) is reported as NO VERDICT
      and fails the whole script -- it is never counted as killed;
    * the baseline (unmutated) proof must PASS first, or nothing counts.

Usage:  python3 mutate_targets.py [target ...]      (default: all)
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent

TARGETS = {
    "hydra_padmux": {
        "sby": HERE / "hydra_padmux.sby",
        "src": ROOT / "common/rtl/hydra_padmux.sv",
        "mutations": [
            ("legality check dropped",
             "if (cfg_sel[p*SELW +: SELW] < NALT)", "if (1'b1)"),
            ("oe not gated by reset",
             "alt_oe [p*NALT + sel_q[p*SELW +: SELW]] & rst_n;",
             "alt_oe [p*NALT + sel_q[p*SELW +: SELW]];"),
            ("lock not sticky",
             "locked_q <= locked_q | cfg_lock;", "locked_q <= cfg_lock;"),
            ("writes accepted while locked",
             "if (cfg_we && !locked_q) begin", "if (cfg_we) begin"),
            ("idle value ignored",
             ": alt_idle[p*NALT + k];", ": 1'b0;"),
            ("wrong reset personality",
             "sel_q    <= RESET_SEL;", "sel_q    <= '0;"),
            ("input routed to wrong alternative",
             "(sel_q[p*SELW +: SELW] == k) ? pad_in[p]",
             "(sel_q[p*SELW +: SELW] != k) ? pad_in[p]"),
            ("unfiltered select register",
             "sel_q    <= sel_d;", "sel_q    <= cfg_sel;"),
        ],
    },
    "hydra_rst_sync": {
        "sby": HERE / "hydra_rst_sync.sby",
        "src": ROOT / "common/rtl/hydra_rst_sync.sv",
        "mutations": [
            ("release after one edge",
             "sync_q <= {sync_q[STAGES-2:0], 1'b1};", "sync_q <= '1;"),
            ("asynchronous release",
             ": sync_q[STAGES-1];", ": arst_n;"),
        ],
    },
    # The tile's SPI target lives with the tile but is proved the same way.
    "hydra_tt_spi": {
        "sby": ROOT / "tt/formal/hydra_tt_spi.sby",
        "src": ROOT / "tt/tile/src/rtl/hydra_tt_spi.sv",
        "mutations": [
            ("byte reported before eight bits",
             "if (bitcnt == 3'd7) begin", "if (bitcnt == 3'd6) begin"),
            ("received byte drops the last bit",
             "rx_byte  <= {rx_sr, copi_b};", "rx_byte  <= {1'b0, rx_sr};"),
            ("frame does not restart on chip select",
             "if (cs_fall) begin\n        bitcnt   <= 3'd0;", "if (1'b0) begin\n        bitcnt   <= 3'd0;"),
            ("rx_valid held for more than a cycle",
             "      rx_valid <= 1'b0;\n      tx_load  <= 1'b0;", "      tx_load  <= 1'b0;"),
            ("transmit loads the wrong byte",
             "if (tx_load) tx_sr <= tx_byte;", "if (tx_load) tx_sr <= ~tx_byte;"),
            ("samples on the falling edge",
             "if (sck_rise) begin", "if (sck_fall) begin"),
        ],
    },
}

TIMEOUT_S = 600


def run_sby(sby_text, src_text, src_name):
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        (td / src_name).write_text(src_text)
        # Point [files] at the (possibly mutated) copy; prove task only.
        lines = []
        for line in sby_text.splitlines():
            if line.strip().startswith("../rtl/"):
                line = str(td / src_name)
            lines.append(line)
        job = td / "job.sby"
        job.write_text("\n".join(lines) + "\n")
        try:
            p = subprocess.run(["sby", "-f", str(job), "prove"], cwd=td,
                               capture_output=True, text=True, timeout=TIMEOUT_S)
        except subprocess.TimeoutExpired:
            return "NO VERDICT (timeout)"
        out = p.stdout
        if "DONE (PASS" in out:
            return "PASS"
        if "DONE (FAIL" in out:
            return "FAIL"
        return "NO VERDICT (" + (out.strip().splitlines() or ["empty output"])[-1] + ")"


def main(names):
    bad = 0
    for name in names:
        t = TARGETS[name]
        sby_text = pathlib.Path(t["sby"]).read_text()
        src = pathlib.Path(t["src"]).read_text()

        # Anchor honesty check BEFORE anything runs.
        for label, frag, _ in t["mutations"]:
            c = src.count(frag)
            if c != 1:
                print(f"STALE ANCHOR {name}: '{label}' matches {c} times: {frag!r}")
                bad += 1
        if bad:
            continue

        base = run_sby(sby_text, src, pathlib.Path(t["src"]).name)
        print(f"{name}: baseline {base}")
        if base != "PASS":
            bad += 1
            continue

        for label, frag, repl in t["mutations"]:
            verdict = run_sby(sby_text, src.replace(frag, repl), pathlib.Path(t["src"]).name)
            if verdict == "FAIL":
                status = "KILLED"
            elif verdict == "PASS":
                status = "SURVIVED"
                bad += 1
            else:
                status = verdict
                bad += 1
            print(f"  {status:9s} {label}")

    if bad:
        print(f"=== {bad} PROBLEM(S) -- NOT ALL MUTATIONS KILLED ===")
        sys.exit(1)
    print("=== ALL MUTATIONS KILLED ===")


if __name__ == "__main__":
    if shutil.which("sby") is None:
        print("sby not found")
        sys.exit(2)
    main(sys.argv[1:] or list(TARGETS))

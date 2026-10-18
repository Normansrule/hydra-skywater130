#!/usr/bin/env python3
"""drt_progress.py -- is detailed routing converging, or stuck?

    python3 tools/drt_progress.py [hardening checkout]   (default ~/src/tinytapeout-hydra)

Reads the newest run's detailed-routing log, prints the violation count after
each optimisation iteration and says whether it is on course for zero within
LibreLane's iteration limit (DRT_OPT_ITERS, 64 by default). Safe to run while
the harden is still going. Nothing is changed.

Exit 0: routed clean, or still on course. Exit 1: projected to finish with
violations (stop the run and give it more area). Exit 2: no log found.

WHY: on 2026-10-13 the v3.1 tile at 3x4 went 10085, 5223, 4558, 4338, 4190
and kept going. The count was falling, so it looked like progress; the rate
was falling faster, so it was never going to reach zero, and a route that
ends with any violation fails sign-off.

The verdict is a projection from the last three iterations, not a guarantee:
the router changes its rip-up strategy between iterations and can sometimes
drop faster late on. A STUCK or NOT CONVERGING verdict that keeps holding for
several more iterations is the signal to stop.
"""
import math
import pathlib
import re
import sys

LIMIT = 64
ITER = re.compile(r"DRT-0195\]\s+Start (\d+)\w* optimization iteration")
VIOL = re.compile(r"DRT-0199\]\s+Number of violations = (\d+)")


def newest_log(hc):
    runs = sorted((hc / "runs").glob("*/"), key=lambda p: p.stat().st_mtime)
    for run in reversed(runs):
        logs = sorted(run.glob("*detailedrouting*/*.log"), key=lambda p: p.stat().st_mtime)
        if logs:
            return logs[-1]
    return None


def counts(text):
    # The router can run more than one pass in one log (on 2026-10-17 a
    # second pass started at 740 right after the first reached 0); iteration
    # numbers restart at 0 for each. Only the newest pass is judged: reading
    # [..., 4, 0, 740] as one sequence reported a clean run as STUCK.
    out, it = [], None
    for line in text.splitlines():
        m = ITER.search(line)
        if m:
            it = int(m.group(1))
            if it == 0:
                out = []
            continue
        m = VIOL.search(line)
        if m:
            out.append((it if it is not None else len(out), int(m.group(1))))
            it = None
    return out


def verdict(seq, limit=LIMIT):
    """(ok, message) for a list of (iteration, violations)."""
    if not seq:
        return True, "no iteration finished yet"
    last_it, last = seq[-1]
    if last == 0:
        return True, f"CLEAN: 0 violations after iteration {last_it}"
    if len(seq) < 4:
        return True, f"{last} violations after iteration {last_it}; too early to judge"
    # Geometric rate over the last three iterations: the fraction kept per step.
    tail = [v for _, v in seq[-4:]]
    keep = (tail[-1] / tail[0]) ** (1 / 3) if tail[0] else 0.0
    left = max(0, limit - 1 - last_it)
    if keep >= 1.0:
        return False, (f"STUCK: {last} violations, not falling over the last three iterations; "
                       "stop the run and give the design more area")
    projected = last * keep ** left
    rate = f"each iteration now removes {100 * (1 - keep):.1f}%"
    if projected >= 1.0:
        need = math.ceil(math.log(1 / last) / math.log(keep)) if keep > 0 else 0
        return False, (f"NOT CONVERGING: {last} violations, {rate}; about {projected:,.0f} would be "
                       f"left at iteration {limit - 1} (zero needs ~{need} more iterations, "
                       f"{left} remain). Stop the run and give the design more area")
    return True, f"ON COURSE: {last} violations, {rate}; projected to reach zero within the limit"


def selftest():
    stuck = [(0, 10085), (1, 5223), (2, 4558), (3, 4338), (4, 4190)]
    good = [(0, 9000), (1, 2100), (2, 400), (3, 60), (4, 7)]
    flat = [(0, 900), (1, 880), (2, 885), (3, 890)]
    assert not verdict(stuck)[0], verdict(stuck)
    assert verdict(good)[0], verdict(good)
    assert not verdict(flat)[0], verdict(flat)
    assert verdict([(5, 0)])[0]
    text = ("[INFO DRT-0195] Start 0th optimization iteration.\n"
            "[INFO DRT-0199]   Number of violations = 10085.\n"
            "[INFO DRT-0195] Start 1st optimization iteration.\n"
            "[INFO DRT-0199]   Number of violations = 5223.\n")
    assert counts(text) == [(0, 10085), (1, 5223)], counts(text)
    two_pass = text + ("[INFO DRT-0195] Start 2nd optimization iteration.\n"
                       "[INFO DRT-0199]   Number of violations = 0.\n"
                       "[INFO DRT-0195] Start 0th optimization iteration.\n"
                       "[INFO DRT-0199]   Number of violations = 740.\n")
    assert counts(two_pass) == [(0, 740)], counts(two_pass)
    assert verdict(counts(two_pass))[0], verdict(counts(two_pass))
    print("PASS drt_progress selftest: stalled, converging, flat, clean and two-pass runs classified")


def main():
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    hc = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "src/tinytapeout-hydra")
    log = newest_log(hc)
    if not log:
        print(f"drt_progress: no detailed-routing log under {hc}/runs/ (has routing started?)")
        return 2
    seq = counts(log.read_text(errors="replace"))
    print(f"drt_progress: {log}")
    for it, v in seq:
        print(f"  iteration {it:2d}  {v:7d}")
    ok, msg = verdict(seq)
    print(msg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

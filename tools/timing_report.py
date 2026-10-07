#!/usr/bin/env python3
"""
timing_report.py -- read a finished harden run and say what clock it can run at.

A harden run that completes with "Setup violations found in the following
corners: *_ss_100C_1v60" has NOT failed -- the layout is fine, DRC and LVS
passed -- but the chip will not reliably run at the declared clock when it is
slow and hot. The fix is a longer clock period, and the number comes from
the run's own metrics, not a guess.

    cd ~/src/tinytapeout-hydra
    python3 ~/src/hydra-skywater130/tools/timing_report.py

It prints worst setup and hold slack per corner, then the clock period that
closes the WORST corner with a margin, and the two edits that apply it:
src/config.json CLOCK_PERIOD and info.yaml clock_hz, which must agree.
"""
import glob, json, math, pathlib, re, sys

# --apply  write the recommended period into the VERIFIED tree's config.json
#          and info.yaml together, so they can never disagree and nobody types
#          a number by hand. (A command once shipped with "NN" as a
#          placeholder; run as written, it put invalid JSON into config.json.)
# --summary print one compact block to paste back for the repository docs.
APPLY    = "--apply" in sys.argv
SUMMARY  = "--summary" in sys.argv
args     = [a for a in sys.argv[1:] if not a.startswith("--")]
run      = pathlib.Path(args[0]) if args else pathlib.Path(".")
VERIFIED = pathlib.Path(__file__).resolve().parent.parent / "tt/tile"


def read_period(cfg_path):
    """CLOCK_PERIOD, tolerating a file the JSON parser rejects -- which is
    exactly the file that most needs repairing."""
    text = cfg_path.read_text()
    try:
        return float(json.loads(text)["CLOCK_PERIOD"])
    except (json.JSONDecodeError, KeyError, ValueError):
        m = re.search(r'"CLOCK_PERIOD"\s*:\s*([0-9.]+)', text)
        return float(m.group(1)) if m else None
metrics = sorted(glob.glob(str(run / "runs/*/final/metrics.json")))
if not metrics:
    print("timing_report: no runs/*/final/metrics.json here -- run from the hardening checkout")
    sys.exit(2)
m = json.load(open(metrics[-1]))
# The period the RUN used lives in the run's own resolved configuration; the
# file in src/ may already have been changed for the next run.
period = None
for rc in sorted(glob.glob(str(run / "runs/*/resolved.json"))):
    try:
        period = float(json.load(open(rc))["CLOCK_PERIOD"])
    except Exception:
        pass
if period is None:
    period = read_period(run / "src/config.json")
if period is None:
    print("timing_report: no usable CLOCK_PERIOD in the run or in src/config.json")
    sys.exit(2)

rows = []
for k, v in m.items():
    if k.startswith("timing__setup__ws__corner:"):
        c = k.split(":", 1)[1]
        rows.append((c, v, m.get(f"timing__hold__ws__corner:{c}"),
                     m.get(f"timing__setup_vio__count__corner:{c}", 0)))
rows.sort(key=lambda r: r[1])

print(f"run:    {metrics[-1]}")
print(f"clock:  CLOCK_PERIOD {period:g} ns  ({1000/period:.2f} MHz)\n")
print(f"  {'corner':24s} {'setup slack':>12s} {'hold slack':>11s} {'setup vio':>10s}")
for c, s, h, n in rows:
    flag = "  <-- fails" if s < 0 else ""
    hs = f"{h:11.3f}" if isinstance(h, (int, float)) else f"{'-':>11s}"
    print(f"  {c:24s} {s:12.3f} {hs} {n:>10}{flag}")

worst = rows[0][1] if rows else 0.0
for k in ("design__max_slew_violation__count", "design__max_cap_violation__count",
          "design__instance__utilization", "route__drc_errors", "magic__drc_error__count",
          "design__lvs_error__count", "antenna__violating__nets"):
    if k in m:
        print(f"  {k:45s} {m[k]}")

if SUMMARY:
    # One block in a fixed format. Every timing number in the READMEs comes
    # from a block like this, pasted back from a real run.
    print("\n----- HYDRA-TIMING (copy from here) -----")
    print(f"period_ns          {period:g}")
    for c, s_, h, n in rows:
        hs = f"{h:.3f}" if isinstance(h, (int, float)) else "-"
        print(f"corner {c:22s} setup {s_:8.3f}  hold {hs:>7s}  vio {n}")
    print(f"critical_path_ns   {period - worst:.3f}   (slowest corner)")
    print(f"fmax_slow_MHz      {1000.0 / (period - worst):.2f}")
    for k in ("design__instance__utilization", "design__max_slew_violation__count",
              "design__max_cap_violation__count", "magic__drc_error__count",
              "design__lvs_error__count", "antenna__violating__nets"):
        if k in m: print(f"{k:34s} {m[k]}")
    print("----- HYDRA-TIMING (to here) -----")

# Sign-off is more than setup slack. An earlier version of this tool said
# "Nothing to change" on a run whose timing closed but whose antenna check
# had failed -- the verdict looked only at setup. Every check that decides
# whether the layout can be manufactured is now part of the verdict.
SIGNOFF = (("magic__drc_error__count", "design rule check (DRC) errors"),
           ("design__lvs_error__count", "layout versus schematic (LVS) errors"),
           ("antenna__violating__nets", "antenna violations (nets)"),
           ("route__drc_errors", "routing DRC errors"))
bad = [(label, m[k]) for k, label in SIGNOFF if k in m and m[k] not in (0, 0.0, None)]
hold_bad = [c for c, _s, h, _n in rows if isinstance(h, (int, float)) and h < 0]

if worst >= 0:
    print(f"\nTiming: every corner meets setup at {period:g} ns ({1000/period:.2f} MHz).")
    if hold_bad:
        print("  BUT hold fails at: " + ", ".join(hold_bad))
    for label, v in bad:
        print(f"  BUT {label}: {v}")
    if bad or hold_bad:
        print("\nNOT READY: timing is fine; fix the sign-off item(s) above and re-harden.")
        if any("antenna" in l for l, _ in bad):
            print("  antenna: raise DRT_ANTENNA_REPAIR_ITERS / DRT_ANTENNA_REPAIR_MARGIN in config.json")
        sys.exit(1)
    print("Sign-off clean: DRC, LVS and antenna all zero. Nothing to change.")
    sys.exit(0)

# The critical path takes period - slack. Close it with 10% margin, then
# round UP to a whole nanosecond so the two files hold a clean number.
need = (period - worst) * 1.10
new = math.ceil(need)
print(f"\nThe worst corner needs {period - worst:.2f} ns; with 10% margin, {need:.2f} ns.")
print(f"Set CLOCK_PERIOD to {new} ns  ->  clock_hz {int(1e9 / new)}  ({1000/new:.2f} MHz)\n")
print("  src/config.json:   \"CLOCK_PERIOD\": %d," % new)
print("  info.yaml:         clock_hz:     %d" % int(1e9 / new))
if APPLY:
    cfg_p, info_p = VERIFIED / "src/config.json", VERIFIED / "info.yaml"
    text = cfg_p.read_text()
    text, n1 = re.subn(r'("CLOCK_PERIOD"\s*:\s*)[^,\n}]+', rf"\g<1>{new}", text)
    json.loads(text)                      # never write invalid JSON
    info = info_p.read_text()
    info, n2 = re.subn(r"(\n\s*clock_hz:\s*)\d+", rf"\g<1>{int(1e9 / new)}", info)
    if n1 != 1 or n2 != 1:
        print(f"timing_report: found {n1} CLOCK_PERIOD and {n2} clock_hz; expected one each. Nothing written.")
        sys.exit(1)
    cfg_p.write_text(text); info_p.write_text(info)
    print(f"\napplied to {VERIFIED}: CLOCK_PERIOD {new}, clock_hz {int(1e9 / new)}")
    print("next: cd ~/src/hydra-skywater130 && ./scripts/sync-tile.sh")

print("\nThen re-harden. Slew and capacitance warnings often shrink with a longer")
print("period too, because the resizer has more slack to trade for smaller drivers.")

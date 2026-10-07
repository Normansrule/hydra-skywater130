#!/usr/bin/env python3
"""
critical_paths.py -- which paths fail timing, and what KIND of path they are.

A longer clock fixes some timing failures and not others. Raising the period
from 55 to 66 ns -- eleven nanoseconds -- did not clear the slow-corner
violations on this tile, which is the signature of a path that does not
scale with the clock. Before changing anything else, find out which paths
they are:

  register -> register    the logic is too deep: a longer clock DOES help
  input    -> register    budget is the period minus the input delay
  register -> output      budget is the period minus the output delay
  RECOVERY / REMOVAL      an asynchronous reset deasserting too close to a
                          clock edge. With thousands of reset flops behind a
                          weak buffer tree the reset arrives late, and a
                          longer clock barely helps. The fix is in the
                          design: synchronise and properly buffer the reset.

Reads the OpenSTA reports the harden run leaves behind, classifies every
violating path it can find, and prints the worst of each kind.

    cd ~/src/tinytapeout-hydra
    python3 ~/src/hydra-skywater130/tools/critical_paths.py
"""
import glob, pathlib, re, sys
from collections import defaultdict

run = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
CORNER = sys.argv[2] if len(sys.argv) > 2 else "nom_ss_100C_1v60"

files = sorted(glob.glob(str(run / f"runs/*/*stapostpnr*/{CORNER}/*.rpt")))
if not files:
    files = sorted(glob.glob(str(run / f"runs/*/*sta*/{CORNER}/*.rpt")))
if not files:
    print(f"critical_paths: no STA reports for corner {CORNER} under {run}/runs/")
    print("  run from the hardening checkout, after a harden that reached post-PnR STA")
    sys.exit(2)

BLOCK = re.compile(r"Startpoint:\s*(\S+)(.*?)Endpoint:\s*(\S+)(.*?)slack\s*\((VIOLATED|MET)\)",
                   re.S)
SLACK = re.compile(r"(-?\d+\.\d+)\s+slack\s*\((VIOLATED|MET)\)")


def kind(start, sdesc, end, edesc, body):
    text = (sdesc + edesc + body).lower()
    if "recovery" in text or "removal" in text or re.search(r"/reset_b\b|/set_b\b", body.lower()):
        return "RECOVERY (async reset)"
    s_in = "input port" in sdesc.lower()
    e_out = "output port" in edesc.lower()
    if s_in and e_out:
        return "input -> output"
    if s_in:
        return "input -> register"
    if e_out:
        return "register -> output"
    return "register -> register"


paths = []
seen = set()
for f in files:
    text = pathlib.Path(f).read_text(errors="replace")
    for m in BLOCK.finditer(text):
        start, sdesc, end, edesc, status = m.groups()
        body = m.group(0)
        sm = SLACK.search(body)
        if not sm:
            continue
        slack = float(sm.group(1))
        key = (start, end, round(slack, 3))
        if key in seen:
            continue
        seen.add(key)
        paths.append((slack, kind(start, sdesc, end, edesc, body), start, end, pathlib.Path(f).name))

viol = sorted(p for p in paths if p[0] < 0)
print(f"corner {CORNER}: {len(files)} report file(s), {len(paths)} paths read, "
      f"{len(viol)} violating\n")
if not viol:
    print("No violating paths in these reports. If the flow still reported setup violations,")
    print("the reports may list only the worst few paths; check the summary with")
    print("  python3 ~/src/hydra-skywater130/tools/timing_report.py --summary")
    sys.exit(0)

groups = defaultdict(list)
for p in viol:
    groups[p[1]].append(p)

print(f"  {'kind':26s} {'count':>6s} {'worst slack':>12s}")
for k, ps in sorted(groups.items(), key=lambda kv: kv[1][0][0]):
    print(f"  {k:26s} {len(ps):6d} {ps[0][0]:12.3f}")

print("\nworst paths:")
for slack, k, s, e, f in viol[:8]:
    print(f"  {slack:8.3f}  {k:24s}  {s}  ->  {e}")

top = viol[0][1]
print("\nwhat that means:")
advice = {
    "RECOVERY (async reset)":
        "the reset network is the problem, not the logic. A longer clock barely helps.\n"
        "  Fix in the design: synchronise the reset's deassertion and let the tools buffer it\n"
        "  as a high-fanout net. Send this output back and that is the next change.",
    "register -> register":
        "logic depth. A longer clock helps; so does a pipeline register on that path.",
    "input -> register":
        "the input delay (a fraction of the period) plus the logic after the pin. Register\n"
        "  the input first, or lengthen the clock.",
    "register -> output":
        "logic between the last register and the pin. Register the output.",
    "input -> output":
        "a combinational path pin to pin. Put a register in it.",
}
print("  " + advice.get(top, top))
print("\nPaste everything from 'corner' down back, and the fix follows from it.")

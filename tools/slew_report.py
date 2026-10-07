#!/usr/bin/env python3
"""
slew_report.py -- which NETS the slew and capacitance warnings come from.

The signed-off tile reports about 5,000 max-slew and 20 max-capacitance
warnings. They do not block sign-off, but a raw count says nothing: 5,000
violations could be 5,000 independent problems or one overloaded net seen at
5,000 pins. This reads the timing tool's violator list (checks.rpt, written by
report_check_types) and the hardened netlist, maps every violating pin to its
net, and names the cell driving that net -- which is what you would change.

    cd ~/src/tinytapeout-hydra
    python3 ~/src/hydra-skywater130/tools/slew_report.py            # slow corner
    python3 ~/src/hydra-skywater130/tools/slew_report.py . nom_tt_025C_1v80

Nothing is changed. Paste the output back; the fix follows from it.
"""
import glob, pathlib, re, sys
from collections import Counter, defaultdict

run = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
CORNER = sys.argv[2] if len(sys.argv) > 2 else "max_ss_100C_1v60"

rpts = sorted(glob.glob(str(run / f"runs/*/*stapostpnr*/{CORNER}/checks.rpt")))
nets = sorted(glob.glob(str(run / "runs/*/final/pnl/*.pnl.v"))) or \
       sorted(glob.glob(str(run / "runs/*/final/nl/*.nl.v")))
if not rpts:
    sys.exit(f"slew_report: no checks.rpt for {CORNER} under {run}/runs/ -- harden first")

# ---- violators from report_check_types -------------------------------------
ROW = re.compile(r"^\s*(\S+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s*(\(VIOLATED\))?")
viol = {"slew": [], "cap": [], "fanout": []}
section = None
for line in pathlib.Path(rpts[-1]).read_text(errors="replace").splitlines():
    low = line.strip().lower()
    if low.startswith("max slew"):        section = "slew";   continue
    if low.startswith("max capacitance"): section = "cap";    continue
    if low.startswith("max fanout"):      section = "fanout"; continue
    if low.startswith("===") or low.startswith("report_"): section = None
    m = ROW.match(line)
    if section and m and m.group(5):
        viol[section].append((m.group(1), float(m.group(2)), float(m.group(3)), float(m.group(4))))

# ---- pin -> net and net -> driver, from the netlist ------------------------
OUT_PINS = {"X", "Y", "Q", "Q_N", "HI", "LO"}
pin_net, driver, loads = {}, {}, Counter()
if nets:
    text = pathlib.Path(nets[-1]).read_text(errors="replace")
    for m in re.finditer(r"\n\s*(sky130_\w+)\s+(\\?\S+)\s*\((.*?)\);", text, re.S):
        cell, inst, body = m.group(1), m.group(2).lstrip("\\"), m.group(3)
        for pm in re.finditer(r"\.(\w+)\s*\(\s*(\\?[^()\s]+(?:\s*\[\d+\])?)\s*\)", body):
            pin, net = pm.group(1), pm.group(2).lstrip("\\").replace(" ", "")
            pin_net[f"{inst}/{pin}"] = net
            if pin in OUT_PINS:
                driver[net] = f"{inst} ({cell.replace('sky130_fd_sc_hd__', '')})"
            else:
                loads[net] += 1

def net_of(pin):
    return pin_net.get(pin, "?")

print(f"corner {CORNER}: {pathlib.Path(rpts[-1]).name}"
      + (f", netlist {pathlib.Path(nets[-1]).name}" if nets else ", NO netlist (pins only)"))
for k in ("slew", "cap", "fanout"):
    v = viol[k]
    if v:
        print(f"  max {k:7s} {len(v):5d} violations, worst slack {min(x[3] for x in v):.3f}")
    else:
        print(f"  max {k:7s}     0")

if not viol["slew"] and not viol["cap"]:
    sys.exit(0)

# Slew is measured where a signal ARRIVES; group by net to find the cause.
by_net = defaultdict(list)
for pin, lim, val, slack in viol["slew"]:
    by_net[net_of(pin)].append(slack)
ranked = sorted(by_net.items(), key=lambda kv: (-len(kv[1]), min(kv[1])))
total = len(viol["slew"])
print(f"\nslew violations come from {len(by_net)} net(s):")
print(f"  {'pins':>5s} {'share':>6s} {'worst':>7s} {'loads':>6s}  net  <-  driver")
cum = 0
for net, sl in ranked[:12]:
    cum += len(sl)
    print(f"  {len(sl):5d} {100*len(sl)/total:5.1f}% {min(sl):7.3f} {loads.get(net, 0):6d}  "
          f"{net}  <-  {driver.get(net, '?')}")
top = sum(len(s) for _, s in ranked[:5])
print(f"  ...the top 5 nets account for {100*top/total:.0f}% of all slew violations")

if viol["cap"]:
    print("\ncapacitance violations (these are DRIVERS -- each is a cell asked to drive too much):")
    for pin, lim, val, slack in sorted(viol["cap"], key=lambda x: x[3])[:12]:
        net = net_of(pin)
        print(f"  {slack:7.3f}  {pin:28s} net {net}  loads {loads.get(net, 0)}")

print("\nreading it:")
if ranked and 100 * top / total >= 50:
    print("  A few nets dominate: buffer or split those nets (or raise the repair effort for")
    print("  high-fanout nets). Fixing them should remove most of the count at once.")
else:
    print("  Violations are spread thin: a design-wide repair setting is more appropriate than")
    print("  fixing nets one by one.")
print("Paste everything from 'corner' down back; nothing has been changed.")

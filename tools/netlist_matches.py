#!/usr/bin/env python3
"""netlist_matches.py -- was this hardened netlist built from this project.v?

    python3 tools/netlist_matches.py <hardened .pnl.v> <src/project.v>

Exit 0 if every design signal name the netlist keeps also appears in
project.v; exit 1, naming the strays, if not.

WHY: on 2026-10-09 the v3 tests were run against the v2 netlist still sitting
in the hardening checkout's runs/ folder, because project.v had changed and
nothing had been re-hardened. 17 of 18 tests failed, all for the same reason
(v2 boots in a different personality), and the log read like a broken design.
Synthesis renames freely, but it keeps register and wire names it does not
optimise away, prefixed with their instance path (\\u_regs.r_lastwd[3]). A
name the netlist has and the source does not means the netlist is older than
the source. The check is one-sided on purpose: the source always has names
synthesis drops.
"""
import re
import sys


def stray_names(netlist_text, source_text):
    words = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", source_text))
    names = set()
    for m in re.finditer(r"\\([A-Za-z_][\w.$\[\]]*)", netlist_text):
        last = m.group(1).split(".")[-1].split("[")[0]
        if re.fullmatch(r"[A-Za-z]\w*", last or ""):
            names.add(last)
    return names, sorted(n for n in names if n not in words)


def main():
    net, src = sys.argv[1], sys.argv[2]
    names, stray = stray_names(open(net).read(), open(src).read())
    if not names:
        print(f"netlist_matches: no design names in {net}; cannot tell, assuming it matches")
        return 0
    if stray:
        print(f"netlist_matches: {net} is NOT from this project.v -- it has "
              f"{len(stray)} signal name(s) the source lacks: {', '.join(stray[:8])}")
        return 1
    print(f"netlist_matches: all {len(names)} design names in the netlist are in project.v")
    return 0


if __name__ == "__main__":
    sys.exit(main())

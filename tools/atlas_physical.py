#!/usr/bin/env python3
"""
atlas_physical.py -- where the tile's RTL modules actually landed.

    python3 tools/atlas_physical.py RUN_DIR [--ladder ID]

Reads one hardened run (RUN_DIR/final: the placed DEF and the powered
netlist) and writes docs/atlas/physical.json for the Physical Layout tab.

There are no module rectangles on a flattened layout. Synthesis flattens
the hierarchy and the placer spreads one module's cells wherever timing and
wire length put them, interleaved with every other module's. So nothing
here draws a region. Each placed cell is attributed to an RTL instance only
when the NETLIST says so: a cell whose output net keeps a hierarchical name
(synthesis keeps register and many wire names, prefixed with their instance
path, e.g. \\u_mom.u_sb.busy_q[2]) belongs to that instance. Every other
logic cell is UNATTRIBUTED and drawn as such; buffers, clock tree, hold and
antenna cells inserted by the flow are their own class. Instances present
in the RTL with no attributed cell are listed as not found in the netlist
(optimised away, or kept only under generated names).

The run must have been built from the submitted tt/tile/src/project.v
(tools/netlist_matches.py), or the tool refuses.
"""
import hashlib, json, pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/atlas/physical.json"
BS = chr(92)


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def parse_def(path):
    units, die, comps = 1000, None, {}
    inc = False
    for line in open(path):
        if line.startswith("UNITS DISTANCE MICRONS"):
            units = int(line.split()[3])
        elif line.startswith("DIEAREA"):
            n = [int(x) for x in re.findall(r"-?\d+", line)]
            die = [n[0] / units, n[1] / units, n[2] / units, n[3] / units]
        elif line.startswith("COMPONENTS"):
            inc = True
        elif line.startswith("END COMPONENTS"):
            break
        elif inc:
            m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)", line)
            if m:
                comps[m.group(1).replace(BS, "")] = (m.group(2), int(m.group(3)) / units, int(m.group(4)) / units)
    return die, comps


OUT_PINS = {"Q", "Q_N", "X", "Y", "COUT", "SUM", "HI", "LO"}


def parse_netlist(path):
    """instance -> (cell type, output nets, input nets)."""
    text = open(path).read()
    out = {}
    for m in re.finditer(r"\n\s*(sky130_fd_sc_hd__\w+)\s+(\S+)\s*\((.*?)\);", text, re.S):
        inst = m.group(2).replace(BS, "")
        outs, ins = [], []
        for pin, net in re.findall(r"\.(\w+)\s*\(\s*([^()]*?)\s*\)", m.group(3)):
            if not net:
                continue
            net = net.replace(BS, "").strip()
            (outs if pin in OUT_PINS else ins).append(net)
        out[inst] = (m.group(1), outs, ins)
    return out


def cone_owners(cells, flop_owner, kinds):
    """For each logic/buffer cell, the set of RTL instances owning the flops
    its outputs reach through combinational cells: what it computes FOR.
    Iterative, memoised; a flop ends the walk."""
    loads = {}
    for inst, (_, _, ins) in cells.items():
        for n in ins:
            loads.setdefault(n, []).append(inst)
    memo = {}
    for start in cells:
        if kinds.get(start) not in ("logic", "buffer") or start in memo:
            continue
        stack = [(start, False)]
        while stack:
            c, done = stack.pop()
            if c in memo:
                continue
            nxt = [l for n in cells[c][1] for l in loads.get(n, ())]
            if not done:
                stack.append((c, True))
                for l in nxt:
                    if l not in memo and kinds.get(l) in ("logic", "buffer"):
                        stack.append((l, False))
                continue
            s = set()
            for l in nxt:
                k = kinds.get(l)
                if k == "flop":
                    s.add(flop_owner.get(l))
                elif k in ("logic", "buffer"):
                    s |= memo.get(l, set())
            memo[c] = s
    return memo


def klass(macro, inst):
    c = macro.replace("sky130_fd_sc_hd__", "")
    if c.startswith(("fill", "decap", "tapvpwrvgnd", "tap")) or inst.startswith(("FILLER", "TAP", "PHY")):
        return None
    if c.startswith("diode") or inst.startswith("ANTENNA"):
        return "antenna"
    if c.startswith(("df", "edf", "sdf", "dl")):
        return "flop"
    if inst.startswith(("clkbuf", "clkload")) or c.startswith("clkinv") and inst.startswith("clk"):
        return "clock"
    if inst.startswith(("hold",)):
        return "hold"
    if inst.startswith(("fanout", "load_slew", "wire", "max_cap", "input", "output", "rebuffer", "split")):
        return "buffer"
    if c.startswith("conb"):
        return "tie"
    return "logic"


def owner(nets, instances):
    """The deepest RTL instance a hierarchical output net name points into."""
    best = None
    for n in nets:
        if "." not in n:
            continue
        parts = n.split(".")[:-1]
        for i in range(len(parts), 0, -1):
            p = ".".join(parts[:i])
            if p in instances:
                if best is None or len(p) > len(best):
                    best = p
                break
    return best


def main():
    a = sys.argv[1:]
    if not a:
        raise SystemExit(__doc__)
    run = pathlib.Path(a[0]).expanduser()
    ladder = a[a.index("--ladder") + 1] if "--ladder" in a else None
    note = a[a.index("--note") + 1] if "--note" in a else None
    f = run / "final"
    defp = next((f / "def").glob("*.def"))
    nlp = next((f / "nl").glob("*.nl.v"))
    pnl = next((f / "pnl").glob("*.pnl.v"))
    proj = ROOT / "tt/tile/src/project.v"
    r = subprocess.run([sys.executable, str(ROOT / "tools/netlist_matches.py"), str(pnl), str(proj)],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"atlas_physical: {pnl} was not built from {proj}:\n{r.stdout}{r.stderr}")
    derived = json.loads((ROOT / "docs/atlas/derived.json").read_text())
    inst_paths = {i["path"].split(".", 1)[1] for i in derived["builds"]["tile"]["instances"] if "." in i["path"]}
    inst_paths |= {p.rsplit(".", 1)[0] for p in list(inst_paths) if "." in p}
    die, comps = parse_def(defp)
    cells = parse_netlist(nlp)
    kinds = {i: klass(c[0], i) for i, c in cells.items()}
    named = {i: owner(c[1], inst_paths) for i, c in cells.items() if kinds[i] in ("flop", "logic")}
    flop_owner = {i: o for i, o in named.items() if kinds[i] == "flop"}
    cones = cone_owners(cells, flop_owner, kinds)
    groups, counts = {}, {}
    for inst, (macro, x, y) in comps.items():
        k = klass(macro, inst)
        if k is None:
            continue
        mod = named.get(inst)
        if mod:
            key = mod                                     # by its own net name
        elif k == "logic" and len(cones.get(inst, set()) - {None}) == 1 and None not in cones.get(inst, {None}):
            key = "~" + next(iter(cones[inst]))           # inferred: drives only that instance's flops
        elif k in ("flop", "logic"):
            key = "(unattributed " + k + ")"
        else:
            key = "(" + k + ")"
        groups.setdefault(key, []).extend([round(x, 1), round(y, 1)])
        counts[key] = counts.get(key, 0) + 1
    metrics = json.loads((f / "metrics.json").read_text())
    pick = {k: metrics.get(k) for k in (
        "design__instance__utilization", "timing__setup__ws", "timing__hold__ws",
        "design__max_slew_violation__count", "design__max_cap_violation__count",
        "magic__drc_error__count", "design__lvs_error__count", "antenna__violating__nets",
        "route__drc_errors", "design__instance__count", "design__die__bbox", "design__core__bbox")}
    found = {k.lstrip("~") for k in groups if not k.startswith("(")}
    rtl_insts = sorted(i["path"].split(".", 1)[1] for i in derived["builds"]["tile"]["instances"] if "." in i["path"])
    out = {
        "_comment": "Generated by tools/atlas_physical.py. Cells attributed by netlist net names only.",
        "run": {"dir": str(run), "ladder": ladder, "def": defp.name, "def_sha256": sha(defp),
                "netlist_sha256": sha(pnl), "metrics_sha256": sha(f / "metrics.json"),
                "project_v_sha256": sha(proj),
                "commit_id_json": json.loads((f / "commit_id.json").read_text()) if (f / "commit_id.json").exists() else None,
                "matches_project_v": r.stdout.strip(), "note": note},
        "die_um": die, "metrics": pick, "counts": counts, "cells": groups,
        "rtl_instances": rtl_insts,
        "not_found": [p for p in rtl_insts if not any(k == p or k.startswith(p + ".") for k in found)],
    }
    OUT.write_text(json.dumps(out, separators=(",", ":"), sort_keys=True) + "\n")
    tot = sum(counts.values())
    attributed = sum(v for k, v in counts.items() if not k.startswith(("(", "~")))
    inferred = sum(v for k, v in counts.items() if k.startswith("~"))
    print(f"atlas_physical: {tot} placed cells (fill and taps excluded), {attributed} attributed "
          f"to an RTL instance by net name, {inferred} inferred from the flops they drive; wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KiB)")
    for k in sorted(counts, key=lambda k: -counts[k]):
        print(f"  {counts[k]:6d}  {k}")


if __name__ == "__main__":
    main()

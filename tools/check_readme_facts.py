#!/usr/bin/env python3
"""check_readme_facts.py -- every number the READMEs quote about the hardened tile, its gate-level recording and
the atlas must equal the repository's own data (make readme-check).

gen_readme_hero.py already checks utilisation and setup slack. This covers the rest of the prose: the layout counts
(die.json, read from the run's DEF), the gate-level recording (die-gl.json and die-gl.bin), the recorded decision
(docs/atlas/traces/crossover.json), hold, slew and capacitance (docs/timing.json, read from checks.out), the test
counts (docs/metrics.json) and the atlas's own inventory. A sentence that quotes an older harden by name ("v3.4")
is left to the history checks. Found by the 2026-10-27 audit: nothing compared these numbers with their sources,
so a re-harden or a re-recording could leave the prose quoting the previous run.
"""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))


def tile_breaks():
    """How many deliberate breaks tt/tile/test/mutate_sim.py lists (its MUTATIONS table)."""
    import ast
    tree = ast.parse((ROOT / "tt/tile/test/mutate_sim.py").read_text())
    return next(len(n.value.elts) for n in ast.walk(tree)
                if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "MUTATIONS")


def gather():
    import atlas_site
    spec, cards, derived, traces, _, _, _, die = atlas_site.load()
    f = atlas_site.die_facts(die, traces)
    runs = json.loads((ROOT / "docs/timing.json").read_text())["runs"]
    t = runs[-1]
    m = json.loads((ROOT / "docs/metrics.json").read_text())
    ver = {v["target"]: v["result"] for v in m["verification"]}
    sel = f["sel"]
    c = lambda n: f"{n:,}"
    want = {
        "cells": c(f["cells"]), "nets": c(f["nets"]), "switched": c(f["switched"]),
        "share": f'{f["switched"] / f["nets"] * 100:.0f}%', "changes": c(f["changes"]),
        "window": str(f["c1"] - f["c0"] + 1), "vias": c(f["vias"]),
        "metal": {k[-1]: c(v) for k, v in f["wires"].items() if k.startswith("met")},
        "decision": str(sel["c"] - f["go"]), "margin": str(sel["margin"]),
        "slew": c(t["slew_violations"]), "slew_corners": t["slew_by_corner"],
        "hold": f'+{min(x[2] for x in t["corners"]):.3f} ns', "setup": f'+{min(x[1] for x in t["corners"]):.2f} ns',
        "tile": ver["tile"], "tile_gl": ver["tile-gl"],
        "builds": str(len(derived["builds"])), "cards": str(sum(1 for k in cards if not k.startswith("_"))),
        "replays": str(len(traces)), "version": t["version"], "breaks": str(tile_breaks()),
        "older": [r["version"] for r in runs[:-1] if r.get("version")],
    }
    return want


def check():
    w = gather()
    bad = []
    tile_n = w["tile"].split(" / ")[0]

    def older(line):
        return any(re.search(rf"\b{re.escape(v)}\b", line) for v in w["older"]) and w["version"] not in line

    for name in ("README.md", "tt/tile/README.md", "tt/tile/docs/info.md", "docs/COMMANDS.md"):
        for i, line in enumerate((ROOT / name).read_text().splitlines(), 1):
            say = lambda what, got, exp: bad.append(f"{name}:{i}: says {got} {what}, the data says {exp}")
            for m in re.finditer(r"(\d{1,3}(?:,\d{3})+) cells", line):
                if m.group(1) != w["cells"]: say("cells", m.group(1), w["cells"])
            for m in re.finditer(r"(\d{1,3}(?:,\d{3})+) (?:n|N)ets", line):
                if m.group(1) not in (w["nets"], w["switched"]): say("nets", m.group(1), f'{w["nets"]} (or {w["switched"]} switched)')
            for m in re.finditer(r"(\d{1,3}(?:,\d{3})*) metal-([1-4])", line):
                if m.group(1) != w["metal"][m.group(2)]: say(f"metal-{m.group(2)} rectangles", m.group(1), w["metal"][m.group(2)])
            for m in re.finditer(r"(\d{1,3}(?:,\d{3})+) vias", line):
                if m.group(1) != w["vias"]: say("vias", m.group(1), w["vias"])
            for m in re.finditer(r"(\d{1,3}(?:,\d{3})+) (?:value changes|changes of value|events)", line):
                if m.group(1) != w["changes"]: say("value changes", m.group(1), w["changes"])
            if w["changes"] in line:
                for m in re.finditer(r"(\d+) cycles", line):
                    if m.group(1) != w["window"]: say("recorded cycles", m.group(1), w["window"])
                for m in re.finditer(r"(\d+)% of the (?:tile's )?nets", line):
                    if m.group(1) + "%" != w["share"]: say("of the nets", m.group(1) + "%", w["share"])
            for m in re.finditer(r"(?:takes|in) about (\d+) cycles", line):
                if m.group(1) != w["decision"]: say("cycles per decision", m.group(1), w["decision"])
            for m in re.finditer(r"margin of (\d+)", line):
                if m.group(1) != w["margin"]: say("cost margin", m.group(1), w["margin"])
            if not older(line):
                for m in re.finditer(r"(\d{1,3}(?:,\d{3})*)(?:\*\*)? slew (?:warnings|violations)", line):
                    if m.group(1) != w["slew"]: say("slew warnings", m.group(1), w["slew"])
                m = re.search(r"slew (\d[\d,]*) / (\d[\d,]*) / (\d[\d,]*)\*{0,2} at the slow corners and (\d+) / (\d+) / (\d+)", line)
                if m:
                    sc = w["slew_corners"]
                    exp = [f"{sc[f'{p}_ss_100C_1v60']:,}" for p in ("max", "nom", "min")] + \
                          [str(sc[f"{p}_tt_025C_1v80"]) for p in ("max", "nom", "min")]
                    if list(m.groups()) != exp: say("slew per corner", " / ".join(m.groups()), " / ".join(exp))
                for m in re.finditer(r"hold (\+\d\.\d{3} ns)", line):
                    if m.group(1) != w["hold"]: say("hold slack", m.group(1), w["hold"])
                for m in re.finditer(r"setup (\+\d+\.\d\d ns)", line):
                    if m.group(1) != w["setup"]: say("setup slack", m.group(1), w["setup"])
                for m in re.finditer(r"\*{0,2}(\d+) / (\d+)\*{0,2} gate-level", line):
                    if f"{m.group(1)} / {m.group(2)}" != w["tile_gl"]: say("gate-level tests", f"{m.group(1)} / {m.group(2)}", w["tile_gl"])
                for m in re.finditer(r"all (\d+) tests pass", line):
                    if m.group(1) != tile_n: say("tests", m.group(1), tile_n)
            for m in re.finditer(r"(\d+) cocotb tests", line):
                if m.group(1) != tile_n: say("tile tests", m.group(1), tile_n)
            for m in re.finditer(r"(\d+) deliberate breaks", line):
                if m.group(1) != w["breaks"]: say("tile mutations", m.group(1), w["breaks"])
            for m in re.finditer(r"each of (\d+) builds", line):
                if m.group(1) != w["builds"]: say("builds", m.group(1), w["builds"])
            for m in re.finditer(r"(\d+) block cards", line):
                if m.group(1) != w["cards"]: say("block cards", m.group(1), w["cards"])
            for m in re.finditer(r"(\d+) replays", line):
                if m.group(1) != w["replays"]: say("replays", m.group(1), w["replays"])
    return bad, w


if __name__ == "__main__":
    bad, w = check()
    if "-v" in sys.argv:
        for k, v in w.items(): print(f"  {k}: {v}")
    if bad:
        print("\n".join("readme-facts: " + b for b in bad)); sys.exit(1)
    print("readme-facts: layout, recording, timing, test, mutation and atlas numbers match their sources")

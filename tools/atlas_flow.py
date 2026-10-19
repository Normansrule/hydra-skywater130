#!/usr/bin/env python3
"""
atlas_flow.py -- one harden, step by step, from its own logs.

    python3 tools/atlas_flow.py RUN_DIR [--checks CHECKS_OUT] [--label TEXT]

Reads every numbered step directory of one LibreLane run (NN-tool-step/,
each with its log) and writes docs/atlas/flow.json for the Build tab: the
steps in order and, where the log states it, the one fact each step is for
(cells after synthesis, die and core area, clock buffers, routing overflow,
antenna, DRC and LVS results). A step whose log says none of these is listed
with its name only. Nothing is estimated: a fact is shown only when a line of
that step's own log or report says it, and the line is kept as evidence.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/atlas/flow.json"

FACTS = [
    # (step name contains, regex, how to say it)
    ("yosys-synthesis", r"Chip area for module '\\?\w+': ([\d.]+)", "cell area after synthesis {0} µm²"),
    ("floorplan", r"Floorplanned on a die area of ([\d. ]+) \(", "die {0} µm"),
    ("floorplan", r"Total\s+(\d+)\s+([\d.]+)", "{0} cells, {1} µm²"),
    ("globalplacement", r"Total\s+(\d+)\s+([\d.]+)", "{0} cells after placement, {1} µm²"),
    ("cts", r"Total number of Buffers Inserted: (\d+)", "{0} clock buffers"),
    ("cts", r"Total number of Sinks: (\d+)", "{0} clock sinks"),
    ("globalrouting", r"^Total\s+\d+\s+\d+\s+([\d.]+%)\s+(\d+) /\s+(\d+) /\s+(\d+)", "routing usage {0}, overflow {3}"),
    ("globalrouting", r"Total wirelength: (\d+) um", "{0} µm of wire"),
    ("detailedrouting", r"Number of violations = (\d+)", "{0} routing violations at the end"),
    ("checkantennas", r"Found (\d+) net violations", "{0} antenna net violations"),
    ("repairantennas", r"Inserted (\d+) diodes", "{0} antenna diodes"),
    ("fillinsertion", r"Total\s+(\d+)\s+([\d.]+)", "{0} instances with fill, {1} µm²"),
    ("magic-drc", r"COUNT: (\d+)", "DRC: {0} errors"),
    ("netgen-lvs", r"(Circuits match uniquely\.|Netlists do not match\.)", "LVS: {0}"),
    ("stapostpnr", None, "timing at every corner (see the status above)"),
]


def step_facts(d):
    name = d.name.split("-", 1)[1] if "-" in d.name else d.name
    logs = sorted(d.glob("*.log")) + sorted(d.glob("reports/*.rpt"))
    text = "\n".join(l.read_text(errors="replace") for l in logs[:3])
    out, lines = [], []
    for key, rx, fmt in FACTS:
        if key not in name:
            continue
        if rx is None:
            out.append(fmt); continue
        ms = list(re.finditer(rx, text, re.M))
        if ms:
            m = ms[-1]
            out.append(fmt.format(*[g.strip() for g in m.groups()]))
            lines.append(m.group(0).strip()[:160])
    return name, out, lines


def main():
    a = sys.argv[1:]
    if not a:
        raise SystemExit(__doc__)
    run = pathlib.Path(a[0]).expanduser()
    label = a[a.index("--label") + 1] if "--label" in a else run.name
    steps = []
    for d in sorted((p for p in run.iterdir() if p.is_dir() and re.match(r"\d+-", p.name)),
                    key=lambda p: int(p.name.split("-")[0])):
        name, facts, lines = step_facts(d)
        steps.append({"n": int(d.name.split("-")[0]), "name": name.replace("-", " "),
                      "detail": "; ".join(facts) if facts else "", "evidence": lines})
    checks = None
    if "--checks" in a:
        checks = pathlib.Path(a[a.index("--checks") + 1]).expanduser().read_text(errors="replace")
    out = {"run": run.name, "what": label, "steps": steps, "label": "Recorded Tool Output",
           "checks_excerpt": "\n".join(checks.splitlines()[:12]) if checks else None}
    OUT.write_text(json.dumps(out, indent=1) + "\n")
    print(f"atlas_flow: {len(steps)} steps of {run.name}, "
          f"{sum(1 for s in steps if s['detail'])} with a fact from their own log; wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

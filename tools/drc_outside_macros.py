#!/usr/bin/env python3
"""drc_outside_macros.py -- split a Magic DRC report into findings inside the
hard macros and findings in the rest of the design.

    python3 tools/drc_outside_macros.py <run dir> [config.json]

WHY. The microcontroller core places eight OpenRAM SRAM macros
(sky130_sram_2kbyte_1rw1r_32x512_8, the PDK's layout). Magic's full DRC on
the final GDS reports tens of millions of findings inside them (bitcell and
SRAM-core rules, 43,487,293 report lines in run 3), while with the macros as
abstract views it reports nwell.4 markers that the real layout does not have.
Neither number says whether the part of the layout this flow drew is clean.
This tool reads the report of a full-GDS run and counts, by rule, what falls
inside a macro's box and what falls outside every macro. It decides nothing
about the macros themselves: their layout is the PDK's, not verified here.

The macro boxes come from config.json (MACROS ... instances: location,
orientation N) and the macro's LEF SIZE. Exits 1 if anything lies outside.
"""
import json
import pathlib
import re
import sys
from collections import Counter


def macro_boxes(cfg_path):
    cfg = json.loads(pathlib.Path(cfg_path).read_text())
    boxes = []
    for name, m in cfg.get("MACROS", {}).items():
        lef = m["lef"][0]
        if lef.startswith("pdk_dir::"):
            import glob, os
            pdk = os.environ.get("PDK_ROOT", str(pathlib.Path.home() / ".ciel"))
            hits = glob.glob(f"{pdk}/ciel/sky130/versions/*/sky130A/{lef[len('pdk_dir::'):]}")
            lef = hits[0]
        size = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", pathlib.Path(lef).read_text())
        w, h = float(size.group(1)), float(size.group(2))
        for inst, place in m["instances"].items():
            if place.get("orientation", "N") not in ("N", "S", "FN", "FS"):
                sys.exit(f"drc_outside_macros: {inst}: orientation {place['orientation']} not handled")
            x, y = place["location"]
            boxes.append((inst, x, y, x + w, y + h))
    return boxes


def main():
    arg = pathlib.Path(sys.argv[1])
    if arg.is_file():                       # a report named directly
        rpt = arg
        run = next(p for p in arg.parents if p.parent.name == "runs")
    else:                                   # a run: its last Magic DRC step
        run = arg
        rpts = sorted(run.glob("*-magic-drc/reports/drc.magic.rpt"),
                      key=lambda p: int(p.parts[-3].split("-")[0]))
        if not rpts:
            sys.exit(f"drc_outside_macros: no Magic DRC report under {run}")
        rpt = rpts[-1]
    cfg = sys.argv[2] if len(sys.argv) > 2 else run.parent.parent / "config.json"
    # An empty report is not a clean one: run 6's Magic died at 21 GiB and
    # left a 0-byte file that the flow counted as 0 errors (2026-11-10).
    if rpt.stat().st_size == 0:
        sys.exit(f"FAIL drc_outside_macros: {rpt} is empty: Magic did not finish, so there is no result")
    boxes = macro_boxes(cfg)
    inside, outside = Counter(), Counter()
    examples = []
    rule = None
    coord = re.compile(r"^\s*(-?[\d.]+)um\s+(-?[\d.]+)um\s+(-?[\d.]+)um\s+(-?[\d.]+)um")
    with open(rpt) as f:
        for line in f:
            m = coord.match(line)
            if m:
                x0, y0, x1, y1 = map(float, m.groups())
                if any(bx0 <= x0 and x1 <= bx1 and by0 <= y0 and y1 <= by1 for _, bx0, by0, bx1, by1 in boxes):
                    inside[rule] += 1
                else:
                    outside[rule] += 1
                    if len(examples) < 10:
                        examples.append(f"{rule}: {line.strip()}")
            elif line.strip() and not line.startswith("-") and not line.startswith("[INFO]"):
                rule = line.strip()
    print(f"drc_outside_macros: {rpt}")
    print(f"  {len(boxes)} macros; {sum(inside.values()):,} findings inside them, {sum(outside.values()):,} outside")
    for r, n in outside.most_common(20):
        print(f"  OUTSIDE {n:>10,}  {r}")
    for e in examples:
        print(f"    e.g. {e}")
    if outside:
        sys.exit(1)
    print("PASS drc_outside_macros: no Magic DRC finding outside the hard macros")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""tile_size_check.py -- is the hardening checkout set up for the tile size
info.yaml asks for, and was the last harden that size?

    python3 tools/tile_size_check.py [hardening checkout]   (default ~/src/tinytapeout-hydra)

Exit 0 if everything present agrees with info.yaml; 1 if anything disagrees.

WHY: on 2026-10-10 the v3 tile was "hardened at 3x4" and came out 4x4.
info.yaml said 3x4, but ./tt/tt_tool.py --harden builds from
src/user_config.json, which only --create-user-config writes, and that had
last been run for v2's 4x4. Sign-off was clean, so nothing complained: the
die size (682.64 x 511.36 um) was the only sign.
"""
import json
import pathlib
import re
import sys

import yaml

# tt-support-tools, tech/sky130A/tile_sizes.yaml (main, fetched 2026-10-11)
TILE_SIZES = {
    "1x1": (161.00, 111.52), "1x2": (161.00, 225.76), "2x2": (334.88, 225.76),
    "3x2": (508.76, 225.76), "3x4": (508.76, 511.36), "4x2": (682.64, 225.76),
    "4x4": (682.64, 511.36), "5x4": (856.52, 511.36), "6x2": (1030.40, 225.76),
    "6x4": (1030.40, 511.36), "8x2": (1378.16, 225.76), "8x4": (1378.16, 511.36),
}


def tiles_for(w, h):
    for k, (tw, th) in TILE_SIZES.items():
        if abs(tw - w) < 0.01 and abs(th - h) < 0.01:
            return k
    return f"{w:.2f} x {h:.2f} um (not a Tiny Tapeout size)"


def main():
    hc = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "src/tinytapeout-hydra")
    want = str(yaml.safe_load((hc / "info.yaml").read_text())["project"]["tiles"])
    bad = 0
    print(f"tile_size_check: info.yaml asks for {want}")

    uc = hc / "src/user_config.json"
    if uc.exists():
        die = json.loads(uc.read_text()).get("DIE_AREA")
        if isinstance(die, str):
            die = die.split()
        if die:
            got = tiles_for(float(die[2]) - float(die[0]), float(die[3]) - float(die[1]))
            ok = got == want
            bad |= not ok
            print(f"  {'ok  ' if ok else 'FAIL'}  src/user_config.json is set up for {got}"
                  + ("" if ok else "  -> run ./tt/tt_tool.py --create-user-config"))
    else:
        print("  --    no src/user_config.json yet: ./tt/tt_tool.py --create-user-config")

    defs = sorted((hc / "runs/wokwi/final/def").glob("*.def"))
    if defs:
        m = re.search(r"DIEAREA\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)",
                      defs[0].read_text(errors="ignore"))
        units = re.search(r"UNITS DISTANCE MICRONS\s+(\d+)", defs[0].read_text(errors="ignore"))
        if m:
            u = int(units.group(1)) if units else 1000
            x0, y0, x1, y1 = (int(v) / u for v in m.groups())
            got = tiles_for(x1 - x0, y1 - y0)
            ok = got == want
            bad |= not ok
            print(f"  {'ok  ' if ok else 'FAIL'}  the last harden (runs/wokwi) is {got}"
                  + ("" if ok else "  -> harden again after --create-user-config"))
    else:
        print("  --    no harden in runs/wokwi yet")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

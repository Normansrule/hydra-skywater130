#!/usr/bin/env python3
"""
tt_ready.py -- is the tile ready to submit to the next Tiny Tapeout shuttle?

It answers in two lists, and the second one matters as much as the first:

  CHECKED HERE   things this script can establish on your machine
  NOT CHECKED    things only the hardening run (the GitHub Action, or
                 LibreLane locally) can establish: placement, routing,
                 timing sign-off, design rules, layout versus schematic

Passing here means the submission is not wrong in any way that can be seen
before hardening. It does NOT mean the tile will harden. Printing "READY"
without the second list would claim more than was checked.

    python3 tools/tt_ready.py            fast checks
    python3 tools/tt_ready.py --full     also synthesise and run the tile tests
"""
import pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TILE = ROOT / "tt/tile"

# From tt-support-tools/tile_sizes.yaml, which is what the tooling uses.
# The template's info.yaml comment abbreviates this list; do not trust it.
KNOWN_TILES = {"1x1", "1x2", "2x2", "3x2", "4x2", "6x2", "8x2", "3x4", "4x4", "5x4"}

errors, warns, oks = [], [], []


def ok(m):   oks.append(m)
def warn(m): warns.append(m)
def err(m):  errors.append(m)


def main():
    full = "--full" in sys.argv
    try:
        import yaml
    except ImportError:
        print("tt_ready: pip install pyyaml"); sys.exit(2)

    info = yaml.safe_load((TILE / "info.yaml").read_text())
    proj = info.get("project", {})

    for f in ("title", "author", "description", "top_module", "tiles",
              "language", "clock_hz", "source_files"):
        (ok if proj.get(f) not in (None, "", []) else err)(f"info.yaml project.{f} set")
    if not proj.get("discord"):
        warn("info.yaml discord is empty -- optional, but it is how the shuttle "
             "team reaches you if something breaks")

    if proj.get("tiles") not in KNOWN_TILES:
        err(f"tiles '{proj.get('tiles')}' is not a size tile_sizes.yaml knows")
    else:
        ok(f"tile size {proj['tiles']} is a valid size")

    pins = info.get("pinout", {})
    empty = [k for k, v in pins.items() if not str(v).strip()]
    if len(pins) != 24:
        err(f"pinout has {len(pins)} entries, expected 24 (ui, uo, uio x 8)")
    elif empty:
        err(f"pinout entries empty: {', '.join(empty)}")
    else:
        ok("pinout: all 24 pins described")

    pv = (TILE / "src/project.v").read_text()
    top = proj.get("top_module", "")
    if not top.startswith("tt_um_"):
        err(f"top_module '{top}' must start with tt_um_")
    if not re.search(rf"\bmodule\s+{re.escape(top)}\b", pv):
        err(f"top_module '{top}' is not defined in src/project.v")
    else:
        ok(f"top module {top} is defined in the submitted source")

    # The converter's helper `_sv2v_0` is initialised in an `initial`
    # statement; that is its standard output and synthesis ignores it. Any
    # OTHER initial statement means state that relies on a power-up value an
    # ASIC does not provide.
    bad_init = [l.strip() for l in pv.splitlines()
                if re.search(r"\binitial\b", l) and "_sv2v_0" not in l]
    if bad_init:
        err(f"{len(bad_init)} initial statement(s) in project.v rely on power-up "
            f"values an ASIC does not have: {bad_init[0][:70]}")
    else:
        ok("no power-up initialisation beyond the converter's own helper")

    # config.json drives hardening; clock_hz in info.yaml documents it. Both
    # must be valid and they must agree. This check did not exist when a
    # placeholder put invalid JSON into config.json and a sync carried it on.
    import json as _json
    try:
        per = float(_json.loads((TILE / "src/config.json").read_text())["CLOCK_PERIOD"])
        ok(f"src/config.json parses; CLOCK_PERIOD {per:g} ns")
        # Every image a README displays must exist. Both READMEs pointed at
        # docs/img/layout.png before anything had rendered it -- on GitHub that
        # is a broken-image icon at the top of the page.
        import re as _re
        for readme in (TILE.parent.parent / "README.md", TILE / "README.md"):
            if not readme.exists(): continue
            for img in _re.findall(r"!\[[^\]]*\]\(([^)\s]+)\)", readme.read_text()):
                if img.startswith("http"): continue
                # ../../workflows/<name>/badge.svg is resolved by GitHub to the
                # Actions badge, not a file in the repository (Tiny Tapeout's
                # standard README badges use exactly this form).
                if img.startswith("../../workflows/"): continue
                if not (readme.parent / img).exists():
                    err(f"{readme.relative_to(TILE.parent.parent)} shows {img}, which does not exist"
                        + (" -- run ./scripts/render-layout.sh" if "layout" in img else ""))
                # tt_tool's full-resolution render was 42 MB on 2026-10-01;
                # copied by hand it would live in git history for good.
                elif (readme.parent / img).stat().st_size > 5 * 1024 * 1024:
                    err(f"{readme.relative_to(TILE.parent.parent)} shows {img}, which is "
                        f"{(readme.parent / img).stat().st_size // (1024*1024)} MB (limit 5 MB)"
                        + (" -- ./scripts/render-layout.sh makes a web-sized copy" if "layout" in img else ""))
        # Deprecated LibreLane aliases (checked against librelane 3.0.14). They
        # are accepted, so nothing fails -- which is the problem: session 139
        # set one believing it changed behaviour, and it was only a second
        # name for a default.
        DEPRECATED = {"GRT_REPAIR_ANTENNAS": "RUN_ANTENNA_REPAIR",
                      "DRT_ANTENNA_MARGIN": "DRT_ANTENNA_REPAIR_MARGIN",
                      "GRT_ANTENNA_ITERS": "GRT_ANTENNA_REPAIR_ITERS",
                      "GRT_ANT_ITERS": "GRT_ANTENNA_REPAIR_ITERS",
                      "GRT_ANTENNA_MARGIN": "GRT_ANTENNA_REPAIR_MARGIN",
                      "GRT_ANT_MARGIN": "GRT_ANTENNA_REPAIR_MARGIN"}
        keys = [k for k, _ in _json.loads((TILE / "src/config.json").read_text(),
                                          object_pairs_hook=lambda kv: kv)]
        stale = [k for k in keys if k in DEPRECATED]
        if stale:
            err("src/config.json uses deprecated LibreLane names: " +
                ", ".join(f"{k} (use {DEPRECATED[k]})" for k in stale))
        else:
            ok("src/config.json uses current LibreLane variable names")
        hz, want = float(proj.get("clock_hz", 0)), 1e9 / per
        if abs(hz - want) / want > 0.01:
            err(f"clock_hz {int(hz)} disagrees with CLOCK_PERIOD {per:g} ns ({int(want)} Hz); "
                f"run tools/timing_report.py --apply")
        else:
            ok(f"clock_hz {int(hz)} agrees with CLOCK_PERIOD {per:g} ns")
    except Exception as e:
        err(f"src/config.json is not valid: {e}")

    md = (TILE / "docs/info.md")
    if not md.exists():
        err("docs/info.md is missing")
    else:
        t = md.read_text().lower()
        for sec in ("how it works", "how to test"):
            (ok if sec in t else err)(f"docs/info.md has a '{sec}' section")

    # Claims that were once true and are not any more. The shared cost engine
    # changed dispatch latency from three cycles to about thirteen, and the
    # old number survived in the submission text until this check existed.
    stale = [("three cycles", "dispatch latency is about thirteen cycles with the shared cost engine")]
    found_stale = False
    for text_file in (TILE / "info.yaml", TILE / "docs/info.md",
                      TILE / "README.md", ROOT / "README.md"):
        body = text_file.read_text().lower()
        for phrase, why in stale:
            if phrase in body:
                err(f"{text_file.name} still says '{phrase}': {why}")
                found_stale = True
    if not found_stale:
        ok("no known-stale claims in info.yaml or docs/info.md")

    regen = subprocess.run(["bash", "regen.sh"], cwd=TILE / "src",
                           capture_output=True, text=True)
    if regen.returncode != 0:
        err("regen.sh failed")
    elif regen.stdout != pv:
        err("src/project.v differs from its sources -- run: cd tt/tile/src && ./regen.sh > project.v")
    else:
        ok("src/project.v is exactly what regen.sh produces from the sources")

    if full:
        r = subprocess.run(
            ["yosys", "-q", "-p",
             f"read_verilog {TILE}/src/project.v; synth -top {top}; stat"],
            capture_output=True, text=True, timeout=900)
        latches = len(re.findall(r"\$_DLATCH|\$dlatch", r.stdout))
        (err if latches else ok)(
            f"{latches} latch(es) inferred" if latches else "no latches inferred")

        t = subprocess.run(["make", "-s"], cwd=TILE / "test",
                           capture_output=True, text=True, timeout=900)
        m = re.search(r"TESTS=(\d+) PASS=(\d+) FAIL=(\d+)", t.stdout)
        if m and m.group(3) == "0":
            ok(f"tile tests: {m.group(2)} of {m.group(1)} pass")
        else:
            err("tile tests did not all pass")

    print("\nCHECKED HERE")
    for m in oks:   print(f"  ok    {m}")
    for m in warns: print(f"  warn  {m}")
    for m in errors: print(f"  FAIL  {m}")
    import hashlib
    fp = hashlib.sha256((TILE / "src/project.v").read_bytes()).hexdigest()[:16]
    print(f"\nFINGERPRINT  src/project.v sha256 {fp}")
    print("  Harden ONLY a checkout whose src/project.v has this hash. A run on")
    print("  2026-09-29 hardened the old tile from a second checkout by mistake;")
    print("  ./scripts/sync-tile.sh copies this tile across and checks the hash.")

    print("\nNOT CHECKED -- only hardening can establish these")
    for m in ("placement fits the tile at the declared size",
              "routing completes with no overflow",
              "setup and hold timing at every corner, at clock_hz",
              "design rule check (Magic and KLayout) is clean",
              "layout versus schematic matches",
              "antenna violations",
              "gate-level simulation of the hardened netlist"):
        print(f"  --    {m}")
    print("\nRun those with the GitHub Action on push, or locally with "
          "./tt/tt_tool.py --harden (see docs/FIRST_TRY.md).")

    if errors:
        print(f"\ntt_ready: NOT READY -- {len(errors)} problem(s) above")
        sys.exit(1)
    print(f"\ntt_ready: nothing wrong that can be seen before hardening"
          f"{'' if full else ' (fast checks; --full also synthesises and runs the tests)'}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""tapeout_facts.py -- the manufacturing facts of each HYDRA-130 target, each
read from a named file by a named command, never typed in.

    python3 tools/tapeout_facts.py [--tile RUN] [--core RUN] [--out docs/tapeout/facts.json]
    python3 tools/tapeout_facts.py --check      # the file still matches its sources

Writes docs/tapeout/facts.json: per target (tt_tile, openframe_core), a list
of facts {name, value, unit, kind, source_file, command, note}. `kind` is one
of "tool output" (read from a hardened run), "PDK file", "TT spec" (Tiny
Tapeout's own tooling in tt/), "upstream file" (a file from another project,
pinned by commit and hash) or "not available" (with what is missing). A fact
whose source is absent is written as "not available", never guessed.

Sources (paths relative to $HOME unless absolute):
  tile run     ~/src/tinytapeout-hydra/runs/wokwi            (final/def, final/lef, resolved.json, final/metrics.json)
  core run     sky130/harden/mcu_core/runs/<latest complete>   (same layout)
  PDK          $PDK_ROOT/ciel/sky130/versions/<hash>/sky130A   (SOURCES, libs.ref)
  TT tooling   ~/src/tinytapeout-hydra/tt                      (tech.py, tech/sky130A/tile_sizes.yaml, docs/PINOUT.md)
  padframes    build/ext/caravel/ (def/chip_io.def, mag/chip_io_openframe.mag), when fetched
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import statistics
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOME = pathlib.Path.home()
TT = HOME / "src/tinytapeout-hydra"


def rel(p):
    p = pathlib.Path(p)
    for base, name in ((ROOT, ""), (HOME, "~/")):
        try:
            return name + str(p.relative_to(base))
        except ValueError:
            pass
    return str(p)


def fact(name, value, unit, kind, source, command, note=""):
    return {"name": name, "value": value, "unit": unit, "kind": kind,
            "source_file": rel(source) if source else "", "command": command, "note": note}


def missing(name, why, command=""):
    return fact(name, None, "", "not available", "", command, why)


def pdk_dir():
    base = pathlib.Path(os.environ.get("PDK_ROOT", HOME / ".ciel")) / "ciel/sky130/versions"
    vs = sorted(base.glob("*/sky130A"))
    if not vs:
        sys.exit("tapeout_facts: no sky130A under PDK_ROOT")
    return vs[0]


def die_area(run):
    d = sorted((run / "final/def").glob("*.def"))[0]
    t = d.read_text(errors="replace")
    dbu = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", t).group(1))
    x0, y0, x1, y1 = map(int, re.search(r"DIEAREA \( (-?\d+) (-?\d+) \) \( (-?\d+) (-?\d+) \)", t).groups())
    w, h = (x1 - x0) / dbu, (y1 - y0) / dbu
    cmd = f"grep -m1 -E 'UNITS|DIEAREA' {rel(d)}"
    return [fact("die width x height", f"{w:.2f} x {h:.2f}", "um", "tool output", d, cmd),
            fact("die area", round(w * h / 1e6, 4), "mm2", "tool output", d, cmd, f"{w * h:,.0f} um2")]


def resolved(run):
    return json.loads((run / "resolved.json").read_text())


def metrics(run):
    m = run / "final/metrics.json"
    return json.loads(m.read_text()) if m.exists() else {}


def metal_layers(run, pdk):
    r = resolved(run)
    tlef = pdk / "libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef"
    routing = re.findall(r"LAYER (\S+)\s*\n\s*TYPE ROUTING", tlef.read_text())
    lo, hi = r.get("RT_MIN_LAYER"), r.get("RT_MAX_LAYER")
    used = routing[routing.index(lo):routing.index(hi) + 1] if lo in routing and hi in routing else []
    pdn = [r.get(k) for k in ("PDN_VERTICAL_LAYER", "PDN_HORIZONTAL_LAYER", "FP_PDN_VERTICAL_LAYER", "FP_PDN_HORIZONTAL_LAYER") if r.get(k)]
    multi = r.get("PDN_MULTILAYER", r.get("FP_PDN_MULTILAYER"))
    return [
        fact("PDK routing layers", ", ".join(routing), "", "PDK file", tlef,
             f"grep -B1 'TYPE ROUTING' {rel(tlef)} | grep LAYER"),
        fact("signal routing layers used", ", ".join(used), "", "tool output", run / "resolved.json",
             f"grep -o '\"RT_M[AI][XN]_LAYER\": \"[a-z0-9]*\"' {rel(run / 'resolved.json')}",
             "li1 also carries standard-cell internal wiring"),
        fact("power grid layers", ", ".join(dict.fromkeys(pdn if multi else pdn[:1])) + f" (+ {r.get('PDN_RAIL_LAYER', 'met1')} cell rails)", "",
             "tool output", run / "resolved.json",
             f"grep -o '\"[A-Z_]*PDN_[A-Z]*LAYER\": \"[a-z0-9]*\"\\|\"[A-Z_]*PDN_MULTILAYER\": [a-z]*' {rel(run / 'resolved.json')}",
             f"PDN_MULTILAYER = {multi}: " + ("straps on both layers" if multi else "vertical straps only, as Tiny Tapeout requires")),
    ]


def voltages(pdk):
    out = []
    sc = pdk / "libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
    t = sc.read_text(errors="replace")
    vm = dict(re.findall(r'voltage_map\("(\w+)",\s*([\d.]+)\)', t))
    cmd = f"grep -m12 voltage_map {rel(sc)}"
    out.append(fact("core supply (standard cells VPWR)", float(vm.get("VPWR", "nan")), "V", "PDK file", sc, cmd,
                    "typical corner library; the slow and fast corners are 1.60 V and 1.95 V (tt/ss/ff library names)"))
    out.append(fact("ground (VGND)", float(vm.get("VGND", vm.get("VSS", "nan"))), "V", "PDK file", sc, cmd))
    io = pdk / "libs.ref/sky130_fd_io/lib/sky130_ef_io__gpiov2_pad_tt_tt_025C_1v80_3v30.lib"
    t = io.read_text(errors="replace")
    vm = dict(re.findall(r'voltage_map\("(\w+)",\s*([\d.]+)\)', t))
    cmd = f"grep -m10 voltage_map {rel(io)}"
    out.append(fact("I/O pad supply (VDDIO)", float(vm["VDDIO"]), "V", "PDK file", io, cmd))
    out.append(fact("I/O pad core-side supply (VCCD)", float(vm["VCCD"]), "V", "PDK file", io, cmd))
    out.append(fact("I/O pad ground (VSS)", float(vm["VSS"]), "V", "PDK file", io, cmd))
    return out


def pad_cell(pdk):
    lef = pdk / "libs.ref/sky130_fd_io/lef/sky130_ef_io.lef"
    t = lef.read_text(errors="replace")
    m = re.search(r"MACRO sky130_ef_io__gpiov2_pad_wrapped.*?SIZE ([\d.]+) BY ([\d.]+)", t, re.S)
    return fact("GPIO pad cell (sky130_ef_io__gpiov2_pad_wrapped) width x height", f"{float(m.group(1)):.3f} x {float(m.group(2)):.3f}", "um",
                "PDK file", lef, f"grep -A6 'MACRO sky130_ef_io__gpiov2_pad_wrapped' {rel(lef)} | grep SIZE",
                "the cell width is the smallest possible pitch; the padframe sets the actual pitch")


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def padframe_pitch(path, cell_re, kind_note):
    """Centre-to-centre spacing of pad cells along each edge, from a DEF (COMPONENTS) or a .mag (use/transform)."""
    p = pathlib.Path(path)
    if not p.exists():
        return missing("I/O pad pitch", f"{rel(p)} not fetched (see docs/tapeout/README.md for the command)",
                       f"python3 tools/tapeout_facts.py after fetching {rel(p)}")
    t = p.read_text(errors="replace")
    pts = []
    if p.suffix == ".def":
        dbu = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", t).group(1))
        for m in re.finditer(r"-\s+\S+\s+(" + cell_re + r")\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", t):
            pts.append((float(m.group(2)) / dbu, float(m.group(3)) / dbu, m.group(4)))
    elif p.suffix == ".mag":
        # Magic layout: "magscale 1 2" makes one unit 0.005 um (sky130 lambda 0.01 um); each "use <cell> <inst>" is
        # followed by "transform a b c d e f" and the child's "box"; the placed corner is the transformed box minimum.
        ms = re.search(r"^magscale (\d+) (\d+)", t, re.M)
        unit = 0.01 * int(ms.group(1)) / int(ms.group(2)) if ms else 0.01
        for m in re.finditer(r"^use (" + cell_re + r")\s+\S+\n(?:(?!use ).*\n)*?transform (-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+)\n"
                             r"box (-?\d+) (-?\d+) (-?\d+) (-?\d+)", t, re.M):
            a, b, c, d, e, f_, x0, y0, x1, y1 = map(int, m.groups()[1:])
            xs = [a * x + b * y + c for x, y in ((x0, y0), (x1, y1))]
            ys = [d * x + e * y + f_ for x, y in ((x0, y0), (x1, y1))]
            pts.append((min(xs) * unit, min(ys) * unit, ""))
    else:
        return missing("I/O pad pitch", f"{rel(p)} is neither a DEF nor a Magic .mag")
    if len(pts) < 4:
        return missing("I/O pad pitch", f"no pad cells matching {cell_re} found in {rel(p)}")
    pitches = []
    for axis, other in ((0, 1), (1, 0)):
        rows = {}
        for pt in pts:
            rows.setdefault(round(pt[other], 1), []).append(pt[axis])
        for xs in rows.values():
            xs = sorted(xs)
            if len(xs) >= 3:
                pitches += [round(b - a, 3) for a, b in zip(xs, xs[1:])]
    if not pitches:
        return missing("I/O pad pitch", f"pad rows in {rel(p)} could not be grouped by edge")
    mode = statistics.mode(pitches)
    return fact("I/O pad pitch (most common centre-to-centre spacing)", mode, "um", "upstream file", p,
                f"python3 tools/tapeout_facts.py   # parses {cell_re} placements in {rel(p)}",
                f"{kind_note}; {len(pts)} pad cells; spacings seen: min {min(pitches)}, max {max(pitches)}; sha256 {sha(p)[:16]}")


def tile_facts(run, pdk):
    f = []
    f += die_area(run)
    sizes = TT / "tt/tech/sky130A/tile_sizes.yaml"
    info = (TT / "info.yaml").read_text()
    tiles = re.search(r'tiles:\s*"(\w+)"', info).group(1)
    m = re.search(rf'{tiles}:\s*"0 0 ([\d.]+) ([\d.]+)"', sizes.read_text())
    f.append(fact(f"Tiny Tapeout {tiles} slot", f"{m.group(1)} x {m.group(2)}", "um", "TT spec", sizes,
                  f"grep {tiles} {rel(sizes)}", "the die area above must equal it"))
    f.append(fact("process / PDK", "SkyWater SKY130 (sky130A), 130 nm", "", "PDK file", pdk / "SOURCES", f"cat {rel(pdk / 'SOURCES')}"))
    f.append(fact("PDK version (open_pdks commit)", (pdk / "SOURCES").read_text().split()[-1], "", "PDK file", pdk / "SOURCES",
                  f"cat {rel(pdk / 'SOURCES')}"))
    lef = sorted((run / "final/lef").glob("*.lef"))[0]
    pins = [p for p in re.findall(r"^\s*PIN (\S+)", lef.read_text(), re.M)]
    power = [p for p in pins if p in ("VPWR", "VGND")]
    sig = [p for p in pins if p not in power]
    f.append(fact("tile pins", len(pins), "pins", "tool output", lef, f"grep -c '^ *PIN ' {rel(lef)}",
                  f"{len(sig)} signal (ui_in 8, uo_out 8, uio_in/out/oe 24, clk, rst_n, ena) + {len(power)} power ({', '.join(power)})"))
    pin_md = TT / "tt/docs/PINOUT.md"
    f.append(fact("package", "64-pin QFN", "", "TT spec", pin_md, f"head -3 {rel(pin_md)}",
                  "the Tiny Tapeout chip's package; the tile reaches it through TT's multiplexer and Caravel's GPIO pads"))
    f += metal_layers(run, pdk)
    tech = TT / "tt/tech.py"
    t = tech.read_text()
    macros = re.search(r"class Sky130Tech.*?mux_macros = \[(.*?)\]", t, re.S).group(1)
    f.append(fact("top metal layer a TT project may use", re.search(r"class Sky130Tech.*?project_top_metal_layer = \"(\w+)\"", t, re.S).group(1),
                  "", "TT spec", tech, f"grep -n project_top_metal_layer {rel(tech)}"))
    f.append(fact("additional IP on the TT chip (not in this design)", "Caravel harness and padframe (management SoC, GPIO pads); TT multiplexer; power gates " +
                  ", ".join(re.findall(r'"([^"]+)"', macros)), "", "TT spec", tech, f"sed -n '/class Sky130Tech/,/extra_logo/p' {rel(tech)}"))
    f.append(pad_cell(pdk))
    f.append(padframe_pitch(ROOT / "build/ext/caravel/def/chip_io.def", r"sky130_ef_io__gpiov2_pad_wrapped",
                            "Caravel's padframe (chip_io), which Tiny Tapeout chips use"))
    f += voltages(pdk)
    f += signoff(run)
    return f


def signoff(run):
    m = metrics(run)
    src = run / "final/metrics.json"
    keys = [("route DRC", "route__drc_errors"), ("Magic DRC", "magic__drc_error__count"), ("LVS errors", "design__lvs_error__count"),
            ("antenna violating nets", "antenna__violating__nets"), ("illegal overlaps", "magic__illegal_overlap__count"),
            ("disconnected pins", "design__disconnected_pin__count"), ("worst setup slack, all corners", "timing__setup__ws"),
            ("worst hold slack, all corners", "timing__hold__ws"), ("max slew violations, all corners", "design__max_slew_violation__count"),
            ("max capacitance violations, all corners", "design__max_cap_violation__count"),
            ("max fanout violations, all corners", "design__max_fanout_violation__count"), ("core utilisation", "design__instance__utilization")]
    out = []
    for label, k in keys:
        if k in m:
            out.append(fact(label, m[k], "ns" if "slack" in label else "", "tool output", src,
                            f"python3 -c \"import json;print(json.load(open('{rel(src)}'))['{k}'])\""))
        else:
            out.append(missing(label, f"{k} not in {rel(src)}"))
    return out


def latest_core_run():
    runs = ROOT / "sky130/harden/mcu_core/runs"
    done = [r for r in runs.glob("pnr*") if (r / "final/metrics.json").exists()]
    return max(done, key=lambda r: int(re.sub(r"\D", "", r.name) or 0)) if done else None


def core_facts(run, pdk):
    f = []
    f += die_area(run)
    f.append(fact("process / PDK", "SkyWater SKY130 (sky130A), 130 nm", "", "PDK file", pdk / "SOURCES", f"cat {rel(pdk / 'SOURCES')}"))
    f.append(fact("PDK version (open_pdks commit)", (pdk / "SOURCES").read_text().split()[-1], "", "PDK file", pdk / "SOURCES",
                  f"cat {rel(pdk / 'SOURCES')}"))
    cfg = ROOT / "sky130/harden/mcu_core/config.json"
    c = json.loads(cfg.read_text())
    n = sum(len(m["instances"]) for m in c.get("MACROS", {}).values())
    f.append(fact("additional IP inside the core", f"{n} x sky130_sram_2kbyte_1rw1r_32x512_8 (OpenRAM, the PDK's sky130_sram_macros)", "",
                  "tool output", cfg, f"python3 -c \"import json;c=json.load(open('{rel(cfg)}'));print(c['MACROS'])\""))
    top = ROOT / "sky130/rtl/hydra_openframe_top.sv"
    f.append(fact("chip I/O (OpenFrame)", 44, "GPIO pads",
                  "tool output", top, f"grep -n OPENFRAME_IO_PADS {rel(top)}",
                  "every pad has a function (docs/pins.md); power and ground come from the padframe's own supply pads"))
    f.append(fact("additional IP on the OpenFrame chip (not in this design)", "OpenFrame padframe (44 sky130 GPIO pads, power pads, POR, the "
                  "ChipFoundry harness)", "", "upstream file", ROOT / "docs/pins.md", "sed -n '/## 2. SkyWater 130 OpenFrame chip/,$p' docs/pins.md"))
    f += metal_layers(run, pdk)
    f.append(pad_cell(pdk))
    f.append(padframe_pitch(ROOT / "build/ext/caravel/mag/chip_io_openframe.mag", r"sky130_ef_io__gpiov2_pad",
                            "the OpenFrame padframe layout (chip_io_openframe), GPIO pads only; the wrapper DEF holds no pad cells"))
    f += voltages(pdk)
    f += signoff(run)
    return f


def build(tile_run, core_run):
    pdk = pdk_dir()
    out = {"_comment": "Generated by tools/tapeout_facts.py from the files named in each entry; do not edit. kind: tool output | PDK file | "
                       "TT spec | upstream file | not available.",
           "targets": {}}
    out["targets"]["tt_tile"] = {"run": rel(tile_run), "facts": tile_facts(tile_run, pdk)}
    if core_run:
        out["targets"]["openframe_core"] = {"run": rel(core_run), "facts": core_facts(core_run, pdk)}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tile", default=None, help="tile run (default: ~/src/tinytapeout-hydra/runs/wokwi; with --check, the recorded one)")
    ap.add_argument("--core", default=None, help="core run (default: the latest complete; with --check, the recorded one)")
    ap.add_argument("--out", default=str(ROOT / "docs/tapeout/facts.json"))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    out = pathlib.Path(a.out)
    recorded = json.loads(out.read_text())["targets"] if out.exists() else {}

    def recorded_run(target):
        r = recorded.get(target, {}).get("run")
        return pathlib.Path(os.path.expanduser(r)) if r and r.startswith("~") else (ROOT / r if r else None)

    # --check re-reads the runs the file was written from (the live tile run may
    # be mid-harden or hold another candidate); writing takes the arguments
    tile = pathlib.Path(a.tile) if a.tile else (recorded_run("tt_tile") if a.check else None) or TT / "runs/wokwi"
    core = pathlib.Path(a.core) if a.core else (recorded_run("openframe_core") if a.check else None) or latest_core_run()
    for name, run in (("tile", tile), ("core", core)):
        if run and not (run / "final/def").is_dir():
            sys.exit(f"tapeout_facts: {name} run {rel(run)} has no final/def (a harden in progress, or removed); pass --{name}")
    data = build(tile, core)
    text = json.dumps(data, indent=1) + "\n"
    if a.check:
        if not out.exists() or out.read_text() != text:
            sys.exit(f"tapeout_facts: {rel(out)} is out of date: run python3 tools/tapeout_facts.py")
        print(f"tapeout-facts: {rel(out)} matches its sources")
        return
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    for t, d in data["targets"].items():
        na = sum(1 for x in d["facts"] if x["kind"] == "not available")
        print(f"{t}: {len(d['facts'])} facts from {d['run']}, {na} not available")
    print(f"wrote {rel(out)}")


if __name__ == "__main__":
    main()

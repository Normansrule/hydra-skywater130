#!/usr/bin/env python3
"""shuttle_check.py -- how ready the full HYDRA-130 chip is for each shuttle other than Tiny Tapeout.

    python3 tools/shuttle_check.py                # print the table, write docs/tapeout/shuttles.json
    python3 tools/shuttle_check.py --target openframe
    python3 tools/shuttle_check.py --check        # fail if docs/tapeout/shuttles.json no longer matches

The Tiny Tapeout tile is NOT a target here: it has its own flow (tt/tile, make tile, make tile-gl, the
tinytapeout-hydra GitHub Actions) and stays scheduler-only. This tool is for the full chip (sky130/rtl,
hydra_openframe_top.sv) on a shuttle that takes a whole padframe user area.

Targets and what each check reads (every result comes from a file or a tool run; nothing is typed in):

  openframe   ChipFoundry / Efabless OpenFrame (SKY130, 44 GPIO pads, no management SoC).
              - the wrapper's ports against Caravel's openframe_project_wrapper.def (name, direction, width)
              - the hardened core block fits the wrapper's die (DIE_AREA of sky130/harden/mcu_core/config.json)
              - the core block's sign-off counts from docs/tapeout/facts.json (tools/tapeout_facts.py)
              - wrapper-level harden, mpw-precheck, gate-level simulation, pad-mode check: their own evidence
  caravel     Caravel user project (SKY130, management SoC + user area, Wishbone): needs a pin map of
              HYDRA's 44 pad functions onto Caravel's user I/O; reads user_project_wrapper.def when fetched.
  gf180 / ihp GF180MCU and IHP SG13G2: the RTL is portable (one SKY130 macro behind SRAM=1); listed with
              what a port needs, from Tiny Tapeout's technology files in tt/tech.

Status words: PASS (checked, holds), OPEN (checked, not clean yet), PLANNED (not attempted; the step and
its command are named), BLOCKED (a file or result it needs does not exist yet; what is missing is named).
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/tapeout/shuttles.json"
CARAVEL = ROOT / "build/ext/caravel"
FETCH = "docs/tapeout/README.md, section 'Fetching the padframes'"


def re_nums(t):
    return [float(x.replace(",", "")) for x in re.findall(r"\d[\d,]*\.?\d*", t)]


def item(name, status, evidence, command=""):
    assert status in ("PASS", "OPEN", "PLANNED", "BLOCKED"), status
    return {"check": name, "status": status, "evidence": evidence, "command": command}


def def_pins(path):
    """{base name: (direction or None, width)} from a DEF's PINS section. A pin name listed more than once (one
    entry per shape, as the power pins are) counts once; a DEF written without DIRECTION gives None."""
    t = path.read_text(errors="replace")
    sec = t[t.index("\nPINS "):t.index("END PINS")]
    names, direc = {}, {}
    for m in re.finditer(r"-\s+(\S+)\s+\+\s+NET\s+\S+(.*?);", sec, re.S):
        name, rest = m.group(1), m.group(2)
        d = re.search(r"\+\s+DIRECTION\s+(\w+)", rest)
        base = re.sub(r"\[\d+\]$", "", name)
        names.setdefault(base, set()).add(name)
        if d:
            direc[base] = d.group(1).upper()
    pins = {b: (direc.get(b), len(v)) for b, v in names.items()}
    die = re.search(r"DIEAREA\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)", t)
    dbu = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", t).group(1))
    return pins, [int(v) / dbu for v in die.groups()]


def rtl_ports(path, module, width_macro, width):
    """{name: (direction, width)} from an ANSI SystemVerilog module header (one level, as written in this repo)."""
    t = path.read_text()
    a = t.index(f"module {module}")
    hdr = t[t.index(") (", a) + 3:t.index(");", a)]
    hdr = re.sub(r"//.*", "", hdr)
    ports = {}
    for decl in hdr.split(","):
        decl = decl.strip()
        if not decl:
            continue
        m = re.match(r"(input|output|inout)\s*(?:wire|logic)?\s*(\[[^\]]+\])?\s*(\w+)$", decl)
        if m:
            direc, rng, name = m.group(1).upper(), m.group(2), m.group(3)
            last = (direc, rng)
        else:  # continuation: "inout vdda1" after "inout vdda," is its own decl; a bare name keeps the last type
            name = decl
            direc, rng = last
        w = 1
        if rng:
            hi = rng[1:-1].split(":")[0].replace(f"`{width_macro}", str(width))
            w = eval(hi, {"__builtins__": {}}) + 1
        ports[name] = (direc, w)
    return ports


def openframe():
    out = []
    wdef = CARAVEL / "def/openframe_project_wrapper.def"
    top = ROOT / "sky130/rtl/hydra_openframe_top.sv"
    if not wdef.exists():
        out.append(item("wrapper ports match the OpenFrame harness", "BLOCKED", f"{wdef.relative_to(ROOT)} not fetched ({FETCH})"))
        return out
    pins, die = def_pins(wdef)
    n = int(re.search(r"`define OPENFRAME_IO_PADS (\d+)", top.read_text()).group(1))
    ports = rtl_ports(top, "openframe_project_wrapper", "OPENFRAME_IO_PADS", n)
    miss = sorted(set(pins) - set(ports))
    extra = sorted(set(ports) - set(pins))
    has_dir = any(d for d, _ in pins.values())
    same = (lambda k: pins[k] == ports[k]) if has_dir else (lambda k: pins[k][1] == ports[k][1])
    diff = sorted(k for k in set(pins) & set(ports) if not same(k))
    ok = not (miss or extra or diff)
    out.append(item("wrapper ports match the OpenFrame harness",
                    "PASS" if ok else "OPEN",
                    f"{len(ports)} ports of openframe_project_wrapper in {top.relative_to(ROOT)} against {len(pins)} pin groups "
                    f"({sum(w for _, w in pins.values())} pins) in {wdef.relative_to(ROOT)}"
                    + (f"; names and widths all equal{'' if has_dir else ' (the DEF carries no DIRECTION, so directions are not compared)'}" if ok else
                       f"; missing {miss[:6]}, extra {extra[:6]}, different {[(k, pins[k], ports[k]) for k in diff[:4]]}"),
                    "python3 tools/shuttle_check.py --target openframe"))
    # the block's size from the hardened run the fact sheet names, not from config.json, which may hold a run in progress
    facts = ROOT / "docs/tapeout/facts.json"
    tgt = json.loads(facts.read_text())["targets"]["openframe_core"]
    dfact = next(f for f in tgt["facts"] if f["name"].startswith("die width"))
    bw, bh = (float(v) for v in re_nums(str(dfact["value"]))[:2])
    ww, wh = die[2] - die[0], die[3] - die[1]
    fits = bw <= ww and bh <= wh
    out.append(item("hardened core block fits the wrapper's user area",
                    "PASS" if fits else "OPEN",
                    f"block {bw:g} x {bh:g} um (run {tgt.get('run', '?')}, docs/tapeout/facts.json); wrapper die {ww:g} x {wh:g} um "
                    f"(DIEAREA, {wdef.relative_to(ROOT)}); margin {ww - bw:g} x {wh - bh:g} um for the pad-side routing and power rings",
                    "python3 tools/tapeout_facts.py; grep DIEAREA " + str(wdef.relative_to(ROOT))))
    facts = ROOT / "docs/tapeout/facts.json"
    core = {f["name"]: f for f in json.loads(facts.read_text())["targets"]["openframe_core"]["facts"]} if facts.exists() else {}
    def val(k):
        return core.get(k, {}).get("value")
    hard = {k: val(k) for k in ("Magic DRC", "LVS errors", "antenna violating nets")}
    if all(v == 0 for v in hard.values()):
        out.append(item("core block sign-off: DRC, LVS, antenna", "PASS",
                        f"{hard} from docs/tapeout/facts.json (run {json.loads(facts.read_text())['targets']['openframe_core'].get('run', '?')})",
                        "python3 tools/tapeout_facts.py"))
    else:
        out.append(item("core block sign-off: DRC, LVS, antenna", "OPEN" if hard else "BLOCKED", f"{hard}", "python3 tools/tapeout_facts.py"))
    warn = {k: val(k) for k in ("max slew violations, all corners", "max capacitance violations, all corners", "max fanout violations, all corners")}
    out.append(item("core block electrical warnings", "PASS" if all(v == 0 for v in warn.values()) else "OPEN",
                    f"{warn}; the SRAM macro's own library caps addr0/addr1/wmask0 at 0.04 ns, its characterised range, "
                    "which no SKY130 driver reaches (docs/tapeout/README.md)", "python3 tools/tapeout_facts.py"))
    out.append(item("wrapper-level harden (core placed in openframe_project_wrapper, power connected, pads wired)", "PLANNED",
                    "no run yet: the core is hardened as a block; the wrapper flow takes it as a macro inside the 3.166 x 4.766 mm user area",
                    "planned: sky130/harden/openframe_wrapper/config.json (LibreLane, MACROS: hydra_mcu_core)"))
    out.append(item("mpw-precheck on the wrapper GDS", "PLANNED", "needs the wrapper GDS above",
                    "planned: the ChipFoundry/Efabless mpw_precheck container on gds/openframe_project_wrapper.gds"))
    out.append(item("gate-level simulation of the chip", "BLOCKED",
                    "the chip is simulated through its pads in RTL (make sky130-mcu); no gate-level netlist of the wrapper exists",
                    "make sky130-mcu"))
    out.append(item("pad modes (dm, input disable) against the pad's own model", "BLOCKED",
                    "sky130/rtl/hydra_openframe_top.sv states the Caravel/OpenFrame convention it uses (dm = 3'b110 output) and that it "
                    "has not been checked against the sky130_fd_io__gpiov2 model", "planned: a testbench with the PDK's gpiov2 Verilog model"))
    return out


def caravel():
    out = []
    upw = CARAVEL / "def/user_project_wrapper.def"
    pins_doc = ROOT / "docs/pins.md"
    if not upw.exists():
        out.append(item("user-area I/O count against HYDRA's 44 pad functions", "BLOCKED",
                        f"{upw.relative_to(ROOT)} not fetched; Caravel's user wrapper DEF sets how many user I/O pads exist",
                        "curl -sSfL -o build/ext/caravel/def/user_project_wrapper.def "
                        "https://raw.githubusercontent.com/efabless/caravel/27cbe49/def/user_project_wrapper.def"))
    else:
        pins, die = def_pins(upw)
        io = pins.get("io_in", (None, 0))[1]
        out.append(item("user-area I/O count against HYDRA's 44 pad functions", "PASS" if io >= 44 else "OPEN",
                        f"{io} io_in pins in {upw.relative_to(ROOT)}; HYDRA assigns 44 pad functions ({pins_doc.relative_to(ROOT)})"
                        + ("" if io >= 44 else f"; {44 - io} functions need sharing or a smaller pin map"),
                        "python3 tools/shuttle_check.py --target caravel"))
    out.append(item("Wishbone or logic-analyzer bridge to the scheduler", "PLANNED",
                    "Caravel's management SoC reaches the user area over Wishbone; HYDRA's host paths today are SPI, I2C and UART on pads",
                    "planned: sys/rtl bridge from Wishbone to the job interface"))
    out.append(item("user_project_wrapper harden and mpw-precheck", "PLANNED", "after the pin map", ""))
    return out


def portable(name, tech):
    # Tiny Tapeout's tooling is cloned into the hardening checkout (~/src/tinytapeout-hydra/tt), not into this repo
    t = pathlib.Path.home() / "src/tinytapeout-hydra/tt/tech" / tech
    shown = f"~/src/tinytapeout-hydra/tt/tech/{tech}"
    there = t.exists()
    return [item(f"{name}: technology files available", "PASS" if there else "BLOCKED",
                 f"{shown} {'present (Tiny Tapeout tooling in the hardening checkout)' if there else 'missing (clone the hardening checkout)'}",
                 f"ls {shown}"),
            item(f"{name}: SRAM", "PLANNED",
                 "the CPU's memory is the SKY130 OpenRAM macro behind SRAM=1; SRAM_MODEL=1 is a behavioural stand-in, so a port "
                 "needs that PDK's SRAM macro or flip-flop memory", "sys/rtl/hydra_cpu_sram.sv"),
            item(f"{name}: harden", "PLANNED", "no run; the cell exclusions in the harden configs name SKY130 cells", "")]


TARGETS = {
    "openframe": ("ChipFoundry / Efabless OpenFrame, SKY130", openframe),
    "caravel": ("Caravel user project, SKY130", caravel),
    "gf180": ("GF180MCU (portability)", lambda: portable("GF180MCU", "gf180mcuD")),
    "ihp": ("IHP SG13G2 (portability)", lambda: portable("IHP SG13G2", "ihp-sg13g2")),
}


def build(which):
    return {k: {"title": TARGETS[k][0], "checks": TARGETS[k][1]()} for k in which}


def main(argv):
    which = list(TARGETS)
    if "--target" in argv:
        which = [argv[argv.index("--target") + 1]]
    res = build(which)
    for k, v in res.items():
        print(f"\n{v['title']}  [{k}]")
        for c in v["checks"]:
            print(f"  {c['status']:8s} {c['check']}\n           {c['evidence']}")
    if "--check" in argv:
        old = json.loads(OUT.read_text())
        if old != res:
            sys.exit("shuttle_check: docs/tapeout/shuttles.json is out of date -- run python3 tools/shuttle_check.py")
        print("\nPASS shuttle_check: docs/tapeout/shuttles.json matches its sources")
    elif which == list(TARGETS):
        OUT.write_text(json.dumps(res, indent=1) + "\n")
        print(f"\nwrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main(sys.argv[1:])

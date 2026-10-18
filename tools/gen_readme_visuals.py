#!/usr/bin/env python3
"""
gen_readme_visuals.py -- the README's explanatory figures, drawn from sources.

  chip_package.svg   the SkyWater 130 OpenFrame chip as it would look after
                     tapeout: an ILLUSTRATED package, every one of the 44 pads
                     labelled with its function. Functions are read from
                     sky130/rtl/hydra_openframe_top.sv (the pad localparams)
                     and the tile's pin descriptions in tt/tile/info.yaml. A
                     projection, not a layout: the chip has never been
                     hardened and no package has been chosen.
  connections.svg    what connects to what: host paths, bridge, register map,
                     scheduler, crossbar, engines and memory. Every block is
                     marked with the evidence it has; animated packets show a
                     job going in and a completion coming back.
  capabilities.svg   CPU, GPU, TPU, vector and NTT engines against the
                     evidence ladder (simulated, synthesized, placed and
                     routed, board). Each filled cell names the make target
                     that reproduces it, and the generator refuses a target
                     that does not exist in the Makefile.
  progress.svg       the progress tracker: every milestone per target, done /
                     in progress / planned / blocked, each done item naming
                     the command that proves it (refused if the Makefile has
                     no such target). The bars are counts of those rows, and
                     the tile's slew figure comes from docs/timing.json.

Animation is CSS inside the SVG (GitHub renders it through <img>) and stops
under prefers-reduced-motion, leaving the final, fully labelled state.

    python3 tools/gen_readme_visuals.py           write docs/img/*.svg
    python3 tools/gen_readme_visuals.py --check   fail if a figure is stale
"""
import json, pathlib, re, sys
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/img"

BG, PANEL, EDGE = "#0f1622", "#172131", "#2a3a52"
TXT, TXT2, DIM = "#eef2f7", "#a9b6c6", "#6f7f95"
BLUE, GREEN, PINK, GOLD, SLATE, RED = "#5b9cf5", "#3dbb8a", "#e061b0", "#d6a93c", "#7d8ea3", "#e5484d"
FONT = "font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif"
MONO = "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"

CHECK = "--check" in sys.argv
STALE = []

MOTION = """<style>
  @keyframes hy-pulse { 0%,100% { opacity:.35 } 50% { opacity:1 } }
  @keyframes hy-flow  { from { stroke-dashoffset: 48 } to { stroke-dashoffset: 0 } }
  @keyframes hy-in    { from { opacity:0; transform:translateY(6px) } to { opacity:1; transform:none } }
  .pulse { animation: hy-pulse 2.4s ease-in-out infinite; }
  .flow  { stroke-dasharray: 6 18; animation: hy-flow 1.2s linear infinite; }
  .rise  { opacity:0; animation: hy-in .6s ease-out forwards; }
  @media (prefers-reduced-motion: reduce) {
    .pulse, .flow, .rise { animation: none !important; opacity: 1 !important; transform: none !important; }
  }
</style>"""


def svg(w, h, title, desc, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
            f'role="img" aria-labelledby="t d"><title id="t">{escape(title)}</title>'
            f'<desc id="d">{escape(desc)}</desc>{MOTION}'
            f'<rect width="{w}" height="{h}" rx="18" fill="{BG}"/>{body}</svg>\n')


def write(name, text):
    f = OUT / name
    if CHECK:
        if not f.exists() or f.read_text() != text:
            STALE.append(str(f.relative_to(ROOT)))
        return
    f.write_text(text)


def t(x, y, s, size=13, fill=TXT, anchor="start", weight=400, mono=False, cls=""):
    c = f' class="{cls}"' if cls else ""
    return (f'<text{c} x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" '
            f'style="{MONO if mono else FONT};font-size:{size}px;font-weight:{weight}" fill="{fill}">{escape(s)}</text>')


# ---------------------------------------------------------------------------
# chip package: functions from the RTL
def pad_plan():
    src = (ROOT / "sky130/rtl/hydra_openframe_top.sv").read_text()
    lp = {k: int(v) for k, v in re.findall(r"localparam int (P_\w+|NMUX)\s*=\s*(\d+);", src)}
    npads = int(re.search(r"`define OPENFRAME_IO_PADS (\d+)", src).group(1))
    import yaml
    pins = yaml.safe_load((ROOT / "tt/tile/info.yaml").read_text())["pinout"]
    plan = {}
    plan[lp["P_CLK"]] = ("clock", "clk", "system clock in", GOLD)
    plan[lp["P_RSTN"]] = ("control", "rst_n", "reset, active low", RED)
    plan[lp["P_CONN"]] = ("control", "connect", "strap: 1 connects the pads", RED)
    first, nmux = lp["P_FIRST"], lp["NMUX"]
    assert nmux == 24
    for i in range(24):
        grp, k = ("ui", i) if i < 8 else ("uo", i - 8) if i < 16 else ("uio", i - 16)
        name = f"{grp}[{k}]"
        desc = str(pins.get(name, "") or "unused").strip()
        desc = re.sub(r"^(LEGACY|REGISTER)\s+", "", desc.split(" / ")[-1])
        col = {"ui": BLUE, "uo": GREEN, "uio": PINK}[grp]
        plan[first + i] = (grp, name, desc, col)
    for p in range(npads):
        plan.setdefault(p, ("unused", "—", "unused: input off, output off", SLATE))
    return npads, plan


def short(desc, n):
    """The explanation part of an info.yaml pin description, cut at a word."""
    d = desc.split(" - ", 1)[-1] if " - " in desc else desc
    if len(d) <= n:
        return d
    return d[:n].rsplit(" ", 1)[0].rstrip(",;:") + "…"


def chip_package():
    npads, plan = pad_plan()
    W, H = 1400, 1000
    cx, cy, S = 340, 560, 400                 # package square
    b = []
    b.append(t(48, 64, "HYDRA-130 on SkyWater 130 nm — the chip after tapeout (projection)", 26, TXT, weight=750))
    b.append(t(48, 92, f"Every one of the {npads} OpenFrame pads, labelled from sky130/rtl/hydra_openframe_top.sv and the "
                       "tile's info.yaml. Illustration only: not hardened, no package chosen.", 13.5, TXT2))
    x0, y0 = cx - S / 2, cy - S / 2
    b.append(f'<rect x="{x0-18}" y="{y0-18}" width="{S+36}" height="{S+36}" rx="26" fill="#0b0f16" stroke="{EDGE}" stroke-width="2"/>')
    b.append(f'<rect x="{x0}" y="{y0}" width="{S}" height="{S}" rx="16" fill="#1b2433" stroke="{GOLD}" stroke-opacity=".45" stroke-width="1.5"/>')
    b.append(f'<circle cx="{x0+24}" cy="{y0+24}" r="7" fill="{EDGE}"/>')            # pin-1 mark
    die = 230
    dx, dy = cx - die / 2, cy - die / 2
    b.append(f'<rect x="{dx}" y="{dy}" width="{die}" height="{die}" rx="6" fill="#222f44" stroke="{BLUE}" stroke-opacity=".7"/>')
    for i in range(1, 10):                                                        # cell rows, decorative
        b.append(f'<line x1="{dx+10}" y1="{dy+i*die/10:.1f}" x2="{dx+die-10}" y2="{dy+i*die/10:.1f}" stroke="#ffffff" stroke-opacity=".05"/>')
    b.append(t(cx, cy - 40, "HYDRA-130", 24, TXT, "middle", 800))
    b.append(t(cx, cy - 16, "OpenFrame · sky130", 12.5, TXT2, "middle", mono=True))
    for i, (n, c) in enumerate([("scheduler (MOM)", BLUE), ("pad multiplexer", GOLD), ("SPI register map", BLUE)]):
        b.append(f'<rect x="{dx+22}" y="{cy+2+i*27}" width="{die-44}" height="21" rx="4" fill="{c}" fill-opacity=".16" stroke="{c}" stroke-opacity=".7"/>')
        b.append(t(cx, cy + 17 + i * 27, n, 11.5, TXT, "middle"))
    b.append(t(cx, dy + die - 12, "engines: not yet on the chip", 11, DIM, "middle"))
    # pads: 11 per side, counter-clockwise from the top of the left side
    per = 11
    assert npads == 4 * per
    for idx in range(npads):
        side, k = divmod(idx, per)
        frac = (k + 0.5) / per
        grp, name, desc, col = plan[idx]
        if side == 0:   px, py, ox, oy = x0 - 18, y0 + frac * S, -1, 0
        elif side == 1: px, py, ox, oy = x0 + frac * S, y0 + S + 18, 0, 1
        elif side == 2: px, py, ox, oy = x0 + S + 18, y0 + S - frac * S, 1, 0
        else:           px, py, ox, oy = x0 + S - frac * S, y0 - 18, 0, -1
        ex, ey = px + ox * 24, py + oy * 24
        b.append(f'<line x1="{px:.1f}" y1="{py:.1f}" x2="{ex:.1f}" y2="{ey:.1f}" stroke="{col}" stroke-width="7"/>')
        if grp == "clock":
            b.append(f'<circle class="pulse" cx="{ex:.1f}" cy="{ey:.1f}" r="9" fill="none" stroke="{col}" stroke-width="2"/>')
        lab = f"{idx} {name}" if name != "—" else f"{idx}"
        lx, ly = ex + ox * 8, ey + oy * 8
        if side in (0, 2):
            b.append(t(lx, py + 4, lab, 11.5, col, "end" if side == 0 else "start", 700, True))
        else:
            ang = 90 if side == 1 else -90
            b.append(f'<text x="{lx:.1f}" y="{ly:.1f}" transform="rotate({ang} {lx:.1f} {ly:.1f})" text-anchor="start" '
                     f'dominant-baseline="middle" style="{MONO};font-size:11.5px;font-weight:700" fill="{col}">{escape(lab)}</text>')
    # the pin table: every used pad and what it is for; the unused run is one line
    tx0, rowh = 720, 33
    b.append(t(tx0, 150, "PAD  SIGNAL     WHAT IT IS FOR", 12, TXT2, weight=700, mono=True))
    used = [p for p in range(npads) if plan[p][0] != "unused"]
    for n, idx in enumerate(used):
        col_i, r = divmod(n, 22)
        x, y = tx0 + col_i * 340, 182 + r * rowh
        grp, name, desc, col = plan[idx]
        d = f'style="animation-delay:{n*0.05:.2f}s"'
        b.append(f'<g class="rise" {d}><rect x="{x}" y="{y-15}" width="8" height="20" rx="2" fill="{col}"/>'
                 + t(x + 16, y, f"{idx:>2}", 12.5, TXT2, mono=True) + t(x + 46, y, name, 12.5, col, weight=700, mono=True)
                 + t(x + 122, y, short(desc, 28), 12, TXT) + '</g>')
    unused = [p for p in range(npads) if plan[p][0] == "unused"]
    n = len(used)
    x, y = tx0 + (n // 22) * 340, 182 + (n % 22) * rowh
    b.append(f'<rect x="{x}" y="{y-15}" width="8" height="20" rx="2" fill="{SLATE}"/>'
             + t(x + 16, y, f"{unused[0]}–{unused[-1]}", 12.5, TXT2, mono=True)
             + t(x + 96, y, "unused: input and output off", 12, TXT))
    for i, s in enumerate(["Reset leaves every pad an input.", "Pads 3–26 pass through the pad",
                           "multiplexer and connect only when", "pad 2 (connect) is high at reset."]):
        b.append(t(x, y + (2 + i) * 24, s, 12, TXT2))
    leg = [("clock", GOLD), ("reset and strap", RED), ("ui: inputs (SPI in)", BLUE),
           ("uo: outputs (SPI out, status)", GREEN), ("uio: bidirectional", PINK), ("unused, held off", SLATE)]
    for i, (nm, c) in enumerate(leg):
        lx = 48 + (i % 3) * 300
        ly = H - 52 + (i // 3) * 24
        b.append(f'<rect x="{lx}" y="{ly-11}" width="14" height="14" rx="3" fill="{c}"/>' + t(lx + 22, ly, nm, 13, TXT2))
    write("chip_package.svg", svg(W, H, "HYDRA-130 chip package projection",
          f"An illustrated package for the SkyWater 130 OpenFrame chip with all {npads} pads labelled from the RTL: "
          "pad 0 clock, 1 reset, 2 connect strap, 3 to 10 tile inputs, 11 to 18 tile outputs, 19 to 26 bidirectional, "
          "the rest unused. Not a layout.", "".join(b)))


# ---------------------------------------------------------------------------
# connections
def connections():
    W, H = 1400, 720
    b = [t(48, 64, "What connects to what", 26, TXT, weight=750),
         t(48, 92, "A job goes in from either host, is costed by the scheduler, runs on the cheapest eligible engine, "
                   "and its completion recalibrates the model. Six slots on the chip, five on the tile.", 13.5, TXT2)]

    def box(x, y, w, h, title, sub, col, state, dashed=False):
        da = ' stroke-dasharray="7 5"' if dashed else ""
        return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{col}" fill-opacity=".13" '
                f'stroke="{col}" stroke-width="1.8"{da}/>' + t(x + 14, y + 26, title, 15, TXT, weight=700)
                + t(x + 14, y + 46, sub, 12, TXT2) + t(x + 14, y + h - 12, state, 11.5, col, mono=True))

    # columns
    b.append(box(48, 150, 210, 96, "PC over serial", "UART 115200 8N1", GOLD, "simulated, P&R"))
    b.append(box(48, 290, 210, 96, "PC over JTAG", "probe on Pmod JA", GOLD, "simulated (Basys 3)"))
    b.append(box(320, 210, 200, 120, "Bridge", "one command set,", BLUE, "simulated, P&R"))
    b.append(t(334, 274, "two independent hosts", 12, TXT2))
    b.append(box(580, 210, 200, 120, "SPI register map", "descriptor, GO, results", BLUE, "hardened (tile)"))
    tver = json.loads((ROOT / "docs/timing.json").read_text())["runs"][-1].get("version", "")
    b.append(box(840, 150, 230, 240, "Scheduler (MOM)", "features → cost engine", BLUE, f"hardened (tile {tver})"))
    for i, s in enumerate(["roofline cost per engine", "eligibility before cost", "pick the cheapest", "calibrate on completion"]):
        b.append(t(856, 222 + i * 26, "• " + s, 12.5, TXT))
    b.append(box(840, 450, 230, 96, "Crossbar", "dispatch and completion", BLUE, "simulated, proved"))
    engines = [("CPU (chip only)", "Sixfold RV64, 6 stages", PINK, "scheduled, simulated", False),
               ("Vector unit", "4 lanes × 32-bit", GREEN, "simulated, P&R", False),
               ("TPU", "4×4 INT8 systolic + memory", GREEN, "simulated, P&R", False),
               ("NTT", "Barrett butterflies", GREEN, "simulated", False),
               ("Crypto slot", "latency model", SLATE, "model only", False),
               ("GPU (chip only)", "Pixelstorm 2 SM × 4 × 8", PINK, "scheduled, simulated", False)]
    for i, (n, s, c, st, dash) in enumerate(engines):
        y = 126 + i * 92
        b.append(box(1140, y, 214, 80, n, s, c, st, dash))
    b.append(box(580, 450, 200, 96, "Scratchpad banks", "operands and results", GREEN, "simulated, P&R"))
    # wires (orthogonal) with animated packets
    wires = [
        "M258,198 H290 V250 H320", "M258,338 H290 V290 H320",          # hosts -> bridge
        "M520,270 H580",                                                 # bridge -> regs
        "M780,270 H840",                                                 # regs -> MOM
        "M955,390 V450",                                                 # MOM -> xbar
        "M520,300 H550 V498 H580",                                       # bridge -> banks (host loads)
        "M780,498 H840",                                                 # banks <-> xbar
    ]
    for i in range(6):
        y = 166 + i * 92
        wires.append(f"M1070,498 H1105 V{y} H1140")
    for k, wpath in enumerate(wires):
        b.append(f'<path d="{wpath}" fill="none" stroke="{EDGE}" stroke-width="2.4"/>')
        b.append(f'<path class="flow" d="{wpath}" fill="none" stroke="{BLUE}" stroke-width="2.4" stroke-opacity=".9"/>')
    b.append(t(48, H - 40, "States are the capability matrix's (docs/verification/capability-matrix.md). "
                           "P&R: placed and routed on ECP5. No block has run on a board yet.", 12.5, DIM))
    write("connections.svg", svg(W, H, "HYDRA-130 connections",
          "Host over serial or JTAG into one bridge, then the SPI register map, the scheduler, the crossbar and six engine "
          "slots; scratchpad banks feed the engines and are loaded by the host. The GPU engine is built but not yet a slot.",
          "".join(b)))


# ---------------------------------------------------------------------------
# capabilities
LEVELS = ["simulated", "synthesized", "placed and routed", "on a board"]
CAPS = [  # engine, what, {level: make target or None}, note
    ("TPU", "4×4 INT8 systolic array, memory-fed", {"simulated": "dma", "synthesized": "fpga", "placed and routed": "fpga"}, "ecp5-evn-tpu, ecp5-evn-mem"),
    ("Vector", "4 lanes × 32-bit integer", {"simulated": "dma-simd", "synthesized": "fpga", "placed and routed": "fpga"}, "ecp5-evn-two"),
    ("GPU", "Pixelstorm SIMT, 2 SM × 4 warps × 8 lanes", {"simulated": "systile-gpu", "synthesized": "gpu"}, "the chip's sixth scheduler slot; 62,625 LUT4 on ECP5"),
    ("NTT", "Barrett butterflies, 3 moduli", {"simulated": "ntt-moduli"}, "not in an FPGA image yet"),
    ("CPU", "Sixfold RV64IM + Zba/Zbb/Zbs + Zknh", {"simulated": "systile-cpu"}, "the chip's CPU slot; 24 programs cycle-exact against Sixfold's model"),
    ("Scheduler", "cost model, calibration, tags", {"simulated": "systile", "synthesized": "fpga", "placed and routed": "fpga"}, "also hardened as the Tiny Tapeout tile"),
]


def capabilities():
    mk = (ROOT / "Makefile").read_text()
    for _, _, cells, _ in CAPS:
        for tgt in cells.values():
            if not re.search(rf"^{re.escape(tgt)}:", mk, re.M):
                raise SystemExit(f"gen_readme_visuals: capability cites make {tgt}, which the Makefile does not have")
    W, row = 1400, 90
    H = 170 + len(CAPS) * row + 70
    b = [t(48, 64, "CPU, GPU and TPU on FPGA: where each engine stands", 26, TXT, weight=750),
         t(48, 92, "A filled cell is reached and names the command that shows it. An empty cell is not reached. "
                   "No image has run on a board yet.", 13.5, TXT2)]
    cx0, cw = 500, 210
    for j, lv in enumerate(LEVELS):
        b.append(t(cx0 + j * cw + cw / 2, 140, lv, 14, TXT2, "middle", 700))
    for i, (eng, what, cells, note) in enumerate(CAPS):
        y = 160 + i * row
        b.append(f'<rect x="40" y="{y}" width="{W-80}" height="{row-10}" rx="10" fill="{PANEL}"/>')
        b.append(t(60, y + 28, eng, 18, TXT, weight=750) + t(60, y + 49, what, 12, TXT2))
        b.append(t(60, y + 68, note, 11.5, DIM))
        for j, lv in enumerate(LEVELS):
            x = cx0 + j * cw + 14
            tgt = cells.get(lv)
            col = [GREEN, BLUE, GOLD, PINK][j]
            if tgt:
                d = f'style="animation-delay:{(i*4+j)*0.08:.2f}s"'
                b.append(f'<g class="rise" {d}><rect x="{x}" y="{y+12}" width="{cw-28}" height="{row-34}" rx="8" fill="{col}" fill-opacity=".22" stroke="{col}"/>'
                         + t(x + (cw - 28) / 2, y + 40, f"make {tgt}", 12.5, TXT, "middle", 600, True) + '</g>')
            else:
                b.append(f'<rect x="{x}" y="{y+12}" width="{cw-28}" height="{row-34}" rx="8" fill="none" stroke="{EDGE}" stroke-dasharray="5 5"/>')
    b.append(t(48, H - 30, "From docs/verification/capability-matrix.md. 'make fpga' places and routes the ECP5 images; "
                           "'make systile-gpu' schedules a real GPU kernel on the six-slot chip.", 12.5, DIM))
    write("capabilities.svg", svg(W, H, "Engine capabilities on FPGA",
          "A grid of engines against simulated, synthesized, placed and routed, and on a board. TPU, vector and scheduler "
          "are placed and routed on ECP5; the GPU is simulated and synthesized; NTT simulated; the CPU not integrated; "
          "nothing has run on a board.", "".join(b)))


# ---------------------------------------------------------------------------
# progress tracker
DONE, WIP, PLAN, BLOCK = "done", "in progress", "planned", "blocked"


def milestones():
    """(target, [(milestone, state, evidence)]). A done row's evidence is a
    make target, checked against the Makefile; other rows say what they wait
    on. Numbers come from docs/timing.json, never typed here."""
    runs = json.loads((ROOT / "docs/timing.json").read_text())["runs"]
    t = runs[-1]
    worst = min(c[1] for c in t["corners"])
    return [
        ("Tiny Tapeout tile", [
            ("RTL and 21 cocotb tests", DONE, "tile"),
            (f"hardened clean at 4×4 ({t.get('version', '')}, +{worst:.2f} ns)", DONE, "tile-gl"),
            (f"slew warnings to zero ({t['slew_violations']:,} left, slow corners)", WIP, "one change per harden"),
            ("shuttle submission", PLAN, "owner releases; GDS action builds"),
        ]),
        ("SkyWater 130 chip", [
            ("scheduler, pad multiplexer, SPI through the pads", DONE, "sky130"),
            ("GPU as the sixth scheduler slot", DONE, "systile-gpu"),
            ("ABI version 2: modes, policy, contexts", DONE, "systile-abi"),
            ("Sixfold RV64 CPU on the CPU slot", DONE, "systile-cpu"),
            ("CPU, GPU and TPU in the OpenFrame top", PLAN, "they run in the system tile; the pad top has the scheduler"),
            ("harden the OpenFrame chip", BLOCK, "the CPU memory must become SRAM macros first"),
        ]),
        ("FPGA", [
            ("ECP5 images placed and routed, timing met", DONE, "fpga"),
            ("Basys 3 image, serial and JTAG host paths", WIP, "simulated; Vivado not installed"),
            ("first image on a real board (ULX3S)", BLOCK, "needs the board"),
        ]),
        ("Security", [
            ("key vault, SHA-256, measurement as blocks", DONE, "sha256-stream"),
            ("FHE and SE modes", PLAN, "specifications; refused by host and chip"),
        ]),
    ]


def progress():
    mk = (ROOT / "Makefile").read_text()
    groups = milestones()
    for _, rows in groups:
        for _, st, ev in rows:
            if st == DONE and not re.search(rf"^{re.escape(ev)}:", mk, re.M):
                raise SystemExit(f"gen_readme_visuals: progress cites make {ev}, which the Makefile does not have")
    col = {DONE: GREEN, WIP: GOLD, PLAN: SLATE, BLOCK: RED}
    W, rowh, gap = 1400, 40, 64
    H = 130 + sum(76 + len(r) * rowh for _, r in groups) + 30
    b = [t(48, 64, "Progress", 26, TXT, weight=750),
         t(48, 92, "Every milestone with its state. A done row names the command that proves it; "
                   "the bars count rows, and the numbers come from docs/timing.json.", 13.5, TXT2)]
    y = 130
    k = 0
    for name, rows in groups:
        n_done = sum(1 for _, s, _ in rows if s == DONE)
        b.append(t(48, y + 24, name, 18, TXT, weight=750))
        b.append(t(W - 48, y + 24, f"{n_done} of {len(rows)} done", 13, TXT2, "end"))
        bx, bw = 330, 820
        b.append(f'<rect x="{bx}" y="{y+12}" width="{bw}" height="12" rx="6" fill="{PANEL}"/>')
        for j, (_, s, _) in enumerate(rows):
            seg = bw / len(rows)
            b.append(f'<rect class="rise" style="animation-delay:{k*0.06 + j*0.05:.2f}s" x="{bx + j*seg + 1:.1f}" '
                     f'y="{y+12}" width="{seg-2:.1f}" height="12" rx="6" fill="{col[s]}" fill-opacity="{1 if s == DONE else .55}"/>')
        y += 56
        for ms, s, ev in rows:
            k += 1
            d = f'style="animation-delay:{k*0.06:.2f}s"'
            b.append(f'<g class="rise" {d}><rect x="64" y="{y-14}" width="104" height="22" rx="11" fill="{col[s]}" fill-opacity=".2" stroke="{col[s]}"/>'
                     + t(116, y + 2, s, 12, col[s], "middle", 700)
                     + t(186, y + 2, ms, 14, TXT)
                     + t(W - 48, y + 2, ("make " + ev) if s == DONE else ev, 12.5, TXT2 if s != DONE else GREEN, "end",
                         mono=(s == DONE)) + '</g>')
            y += rowh
        y += 20
    write("progress.svg", svg(W, H, "HYDRA-130 progress",
          "The progress tracker: Tiny Tapeout tile, SkyWater 130 chip, FPGA and security milestones, each done, "
          "in progress, planned or blocked, with the command that proves each done item.", "".join(b)))


def main():
    chip_package()
    connections()
    capabilities()
    progress()
    if CHECK:
        if STALE:
            print("\n".join(f"readme-visuals: {s} is out of date -- run: make readme-art" for s in STALE))
            sys.exit(1)
        print("readme-visuals: package, connection, capability and progress figures current")
    else:
        print("gen_readme_visuals: chip_package.svg, connections.svg, capabilities.svg, progress.svg")


if __name__ == "__main__":
    main()

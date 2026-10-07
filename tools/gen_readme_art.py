#!/usr/bin/env python3
"""
gen_readme_art.py -- the README figures, drawn from the repository's own data.

Same rule as the project page: a picture typed by hand drifts. Each figure
here reads the file that DEFINES what it shows:

  pinout.svg        tt/tile/info.yaml `pinout`          (what the shuttle sees)
  fpga_wiring.svg   the board file + the bring-up plan   (core port -> ball)
  architecture.svg  the block list in gen_site.py        (every block a file)
  area.svg          docs/metrics.json                    (measured numbers)

Figures have their own white card behind them so they read on GitHub's light
AND dark themes: an SVG shown through <img> cannot see the page's theme.

The one figure NOT drawn here is the real layout. That comes from your
hardened GDS, rendered by Tiny Tapeout's own tool:
    cd ~/src/tinytapeout-hydra && ./tt/tt_tool.py --create-png
"""
import json, pathlib, re, sys
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = [ROOT / "docs/img", ROOT / "tt/tile/docs/img"]      # both repositories

INK, DIM, LINE, CARD = "#111827", "#5b6576", "#d6dce5", "#ffffff"
TEAL, AMBER, VIOLET = "#0f766e", "#b45309", "#6d28d9"
FONT = "font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif"
MONO = "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"


def card(w, h, body, title=None):
    t = (f'<text x="24" y="34" style="{FONT};font-size:17px;font-weight:700" '
         f'fill="{INK}">{escape(title)}</text>') if title else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'width="{w}" height="{h}" role="img" aria-label="{escape(title or "")}">'
            f'<rect x="1" y="1" width="{w-2}" height="{h-2}" rx="14" fill="{CARD}" '
            f'stroke="{LINE}"/>{t}{body}</svg>\n')


def write(name, svg, repos=OUT):
    for d in repos:
        d.mkdir(parents=True, exist_ok=True)
        (d / name).write_text(svg)


# ---------------------------------------------------------------------------
def pinout():
    """Both personalities per pin, on separate lines, so neither is truncated
    into the other. info.yaml writes them as 'LEGACY x / REGISTER y'."""
    import yaml
    info = yaml.safe_load((ROOT / "tt/tile/info.yaml").read_text())
    pins = info["pinout"]

    def split(desc):
        desc = str(desc).strip()
        leg, reg = desc, ""
        if " / " in desc:
            leg, reg = desc.split(" / ", 1)
        leg = re.sub(r"^LEGACY\s+", "", leg)
        reg = re.sub(r"^REGISTER\s+", "", reg)
        if not reg and not desc.startswith("LEGACY"):
            reg = "same in both"
        cut = lambda t, n: t if len(t) <= n else t[:n-1] + "…"
        return cut(leg, 46), cut(reg, 46)

    w, row, top = 1500, 42, 96
    chip_x, chip_w = 560, 380
    h = top + 8 * row + 250
    body = []
    body.append(f'<text x="24" y="58" style="{FONT};font-size:12.5px" fill="{DIM}">'
                f'Each pin has two personalities, selected by a strap at reset: '
                f'<tspan fill="{INK}" font-weight="600">LEGACY</tspan> (the v1 serial interface) and '
                f'<tspan fill="{VIOLET}" font-weight="600">REGISTER</tspan> (the SPI register map).</text>')
    body.append(f'<rect x="{chip_x}" y="{top}" width="{chip_w}" height="{8*row+6}" rx="12" '
                f'fill="#f3f6fa" stroke="{INK}" stroke-width="1.6"/>')
    body.append(f'<text x="{chip_x+chip_w/2}" y="{top+4*row-4}" text-anchor="middle" '
                f'style="{FONT};font-size:21px;font-weight:700" fill="{INK}">tt_um_hydra_mom</text>')
    body.append(f'<text x="{chip_x+chip_w/2}" y="{top+4*row+20}" text-anchor="middle" '
                f'style="{MONO};font-size:12.5px" fill="{DIM}">'
                f'{escape(info["project"]["tiles"])} tiles · sky130 · {int(info["project"]["clock_hz"])//1_000_000} MHz</text>')

    for i in range(8):
        y = top + i * row + row / 2 + 3
        for prefix, colour, left in (("ui", TEAL, True), ("uo", AMBER, False)):
            leg, reg = split(pins.get(f"{prefix}[{i}]", ""))
            if left:
                body.append(f'<line x1="{chip_x-34}" y1="{y}" x2="{chip_x}" y2="{y}" stroke="{colour}" stroke-width="2.2"/>'
                            f'<text x="{chip_x+12}" y="{y+4}" style="{MONO};font-size:12.5px;font-weight:700" fill="{colour}">{prefix}[{i}]</text>')
                tx, anc = chip_x - 44, "end"
            else:
                body.append(f'<line x1="{chip_x+chip_w}" y1="{y}" x2="{chip_x+chip_w+34}" y2="{y}" stroke="{colour}" stroke-width="2.2"/>'
                            f'<text x="{chip_x+chip_w-12}" y="{y+4}" text-anchor="end" style="{MONO};font-size:12.5px;font-weight:700" fill="{colour}">{prefix}[{i}]</text>')
                tx, anc = chip_x + chip_w + 44, "start"
            body.append(f'<text x="{tx}" y="{y-3}" text-anchor="{anc}" style="{FONT};font-size:12.5px" fill="{INK}">{escape(leg)}</text>')
            if reg:
                body.append(f'<text x="{tx}" y="{y+13}" text-anchor="{anc}" style="{FONT};font-size:11.5px" fill="{VIOLET}">{escape(reg)}</text>')

    body.append(f'<text x="{chip_x-44}" y="{top-12}" text-anchor="end" style="{FONT};font-size:12px;'
                f'font-weight:700;letter-spacing:.08em" fill="{TEAL}">INPUTS · ui_in</text>')
    body.append(f'<text x="{chip_x+chip_w+44}" y="{top-12}" style="{FONT};font-size:12px;'
                f'font-weight:700;letter-spacing:.08em" fill="{AMBER}">OUTPUTS · uo_out</text>')

    by = top + 8 * row + 48
    body.append(f'<text x="44" y="{by}" style="{FONT};font-size:12px;font-weight:700;'
                f'letter-spacing:.08em" fill="{VIOLET}">BIDIRECTIONAL · uio</text>')
    for i in range(8):
        c, r = i % 2, i // 2
        x, y = 44 + c * 720, by + 30 + r * 40
        leg, reg = split(pins.get(f"uio[{i}]", ""))
        body.append(f'<text x="{x}" y="{y}" style="{MONO};font-size:12.5px;font-weight:700" fill="{VIOLET}">uio[{i}]</text>'
                    f'<text x="{x+70}" y="{y}" style="{FONT};font-size:12.5px" fill="{INK}">{escape(leg)}</text>')
        if reg and reg != "same in both":
            body.append(f'<text x="{x+70}" y="{y+15}" style="{FONT};font-size:11.5px" fill="{VIOLET}">{escape(reg)}</text>')
    write("pinout.svg", card(w, h, "".join(body), "HYDRA-130 · Tiny Tapeout pinout"))


# ---------------------------------------------------------------------------
def fpga_wiring():
    import yaml
    board = yaml.safe_load((ROOT / "fpga/boards/ecp5-evn.yaml").read_text())
    plan = yaml.safe_load((ROOT / "plans/ecp5-evn-selftest.yaml").read_text())
    # The board file keeps ordinary pins under `pins:` and the serial port
    # under `uart: {tx, rx}`; the plan names the latter uart_tx / uart_rx.
    sigs = dict(board.get("pins", {}))
    for k, v in board.get("uart", {}).items():
        sigs[f"uart_{k}"] = v

    rows = []
    # Clock and reset first: on a dead board they are the first two things
    # to check, and the plan names them separately from the pin list.
    for key, core in (("clock", plan.get("clock", "clk")), ("reset", plan.get("reset", "rst_n"))):
        b = board.get(key, {})
        if b:
            ball = b.get("pin", "?")
            ball = ball.get("pin", "?") if isinstance(ball, dict) else ball   # nested: pin: {pin: A10}
            rows.append((core, key, b.get("port", "?"), ball))
    for p in plan["pins"]:
        core, bsig = p["core"], p["board"]
        if "[" in bsig and ":" in bsig:                       # a bus: expand it
            name, rng = bsig.split("[")
            hi, lo = (int(v) for v in rng.rstrip("]").split(":"))
            cname = core.split("[")[0]
            for i in range(lo, hi + 1):
                s = sigs.get(f"{name}[{i}]", {})
                rows.append((f"{cname}[{i}]", f"{name}[{i}]", s.get("vendor_name", "?"),
                             s.get("pin", s.get("pins", "?"))))
        else:
            s = sigs.get(bsig, {})
            rows.append((core, bsig, s.get("vendor_name", "?"), s.get("pin", s.get("pins", "?"))))

    w, top, rh = 900, 78, 24
    h = top + len(rows) * rh + 70
    cols = [(34, "CORE PORT", TEAL), (250, "BOARD SIGNAL", INK),
            (470, "SCHEMATIC NAME", DIM), (720, "FPGA BALL", AMBER)]
    body = [f'<text x="{x}" y="{top-18}" style="{FONT};font-size:11px;font-weight:700;'
            f'letter-spacing:.08em" fill="{c}">{t}</text>' for x, t, c in cols]
    for i, (core, bs, vend, ball) in enumerate(rows):
        y = top + i * rh
        if i % 2 == 0:
            body.append(f'<rect x="20" y="{y-16}" width="{w-40}" height="{rh}" fill="#f5f7fa"/>')
        body.append(f'<text x="34" y="{y}" style="{MONO};font-size:12px" fill="{TEAL}">{escape(core)}</text>'
                    f'<text x="250" y="{y}" style="{MONO};font-size:12px" fill="{INK}">{escape(bs)}</text>'
                    f'<text x="470" y="{y}" style="{MONO};font-size:12px" fill="{DIM}">{escape(str(vend))}</text>'
                    f'<text x="720" y="{y}" style="{MONO};font-size:13px;font-weight:700" fill="{AMBER}">{escape(str(ball))}</text>')
        body.append(f'<line x1="200" y1="{y-4}" x2="240" y2="{y-4}" stroke="{LINE}"/>'
                    f'<line x1="660" y1="{y-4}" x2="710" y2="{y-4}" stroke="{LINE}"/>')
    body.append(f'<text x="34" y="{h-22}" style="{FONT};font-size:11.5px" fill="{DIM}">'
                f'Lattice ECP5 Evaluation Board (LFE5UM5G-85F-EVN). Balls from the LiteX-Boards platform file,</text>'
                f'<text x="34" y="{h-8}" style="{FONT};font-size:11.5px" fill="{DIM}">'
                f'fetched and checked by make boards. This figure is generated from that file.</text>')
    write("fpga_wiring.svg", card(w, h, "".join(body), "Bring-up image — every pin, core to FPGA ball"),
          repos=[OUT[0]])


# ---------------------------------------------------------------------------
def from_site():
    sys.path.insert(0, str(ROOT / "tools"))
    import gen_site
    m = json.loads((ROOT / "docs/metrics.json").read_text())

    def restyle(svg):
        # The site's figures use CSS variables; a standalone file needs real colours.
        style = (f"<style>.node rect{{fill:#f3f6fa;stroke:{LINE};stroke-width:1.5}}"
                 f".n-label{{{FONT};font-size:14px;font-weight:600;fill:{INK};text-anchor:middle}}"
                 f".n-sub{{{MONO};font-size:11px;fill:{DIM};text-anchor:middle}}"
                 f".edge{{fill:none;stroke:#9aa6b6;stroke-width:1.5}}"
                 f".edge-label{{{MONO};font-size:10px;fill:{DIM};text-anchor:middle}}"
                 f".bar rect{{fill:{TEAL}}}.b-name{{{FONT};font-size:13px;font-weight:600;fill:{INK};text-anchor:end}}"
                 f".b-val{{{MONO};font-size:12px;fill:{DIM}}}</style>")
        svg = svg.replace('class="diagram" ', "").replace('class="bars" ', "")
        svg = svg.replace("currentColor", "#9aa6b6")
        return svg.replace(">", ">" + style + f'<rect width="100%" height="100%" fill="{CARD}"/>', 1)

    write("architecture.svg", restyle(gen_site.svg_diagram()))
    write("area.svg", restyle(gen_site.svg_area(m)), repos=[OUT[0]])


def main():
    pinout()
    fpga_wiring()
    from_site()
    for d in OUT:
        files = sorted(p.name for p in d.glob("*.svg"))
        print(f"gen_readme_art: {d.relative_to(ROOT)}: {', '.join(files)}")


if __name__ == "__main__":
    main()


# ===========================================================================
# Animated figures. SMIL animation inside the SVG itself: it plays when the
# file is shown through <img>, which is how GitHub renders README images, and
# needs no script (GitHub strips scripts from SVGs). Each animation shows a
# behaviour the design actually has, with the real cycle counts.
# ===========================================================================

def anim_dispatch():
    """The shared cost engine sweeping five engines, two cycles each, then
    the argmin choosing one. Real structure: 10 cycles of sweep, then the
    select stage, then the crossbar -- about 13 cycles in all."""
    names = ["CPU", "SIMD", "TPU", "NTT", "Crypto"]
    costs = [34, 21, 9, 27, 40]                       # illustrative; TPU wins
    T = 0.45                                          # seconds per cycle on screen
    total = T * 16
    w, h = 980, 420
    b = []
    b.append(f'<text x="24" y="56" style="{FONT};font-size:12.5px" fill="{DIM}">'
             f'One cost engine evaluates each compute engine in turn — two cycles each, because its second</text>'
             f'<text x="24" y="74" style="{FONT};font-size:12.5px" fill="{DIM}">'
             f'stage reads the calibration factor, an input that must stay put — then the cheapest wins.</text>')
    b.append(f'<line x1="144" y1="198" x2="214" y2="198" stroke="{LINE}" stroke-width="1.4"/>')

    # descriptor arriving
    b.append(f'<rect x="24" y="170" width="120" height="56" rx="9" fill="#f3f6fa" stroke="{LINE}"/>'
             f'<text x="84" y="196" text-anchor="middle" style="{FONT};font-size:13px;font-weight:600" fill="{INK}">descriptor</text>'
             f'<text x="84" y="213" text-anchor="middle" style="{MONO};font-size:10.5px" fill="{DIM}">8×8×8 GEMM</text>')
    b.append(f'<circle r="6" fill="{TEAL}"><animate attributeName="opacity" values="1;1;0;0" '
             f'keyTimes="0;0.08;0.09;1" dur="{total}s" repeatCount="indefinite"/>'
             f'<animateMotion path="M 144 198 L 214 198" dur="{total}s" keyPoints="0;1;1" '
             f'keyTimes="0;0.08;1" calcMode="linear" repeatCount="indefinite"/></circle>')

    # the shared cost engine
    b.append(f'<rect x="214" y="150" width="170" height="96" rx="11" fill="#ecfdf5" stroke="{TEAL}" stroke-width="1.8"/>'
             f'<text x="299" y="186" text-anchor="middle" style="{FONT};font-size:14px;font-weight:700" fill="{INK}">cost engine</text>'
             f'<text x="299" y="206" text-anchor="middle" style="{MONO};font-size:11px" fill="{DIM}">one, shared</text>')
    # The phase alternates every cycle of the sweep: latch the first stage,
    # then capture the second. That pairing IS the two-cycles-per-engine rule.
    for cyc in range(10):
        k0, k1 = (cyc + 1) / 16.0, (cyc + 2) / 16.0
        word = "latch" if cyc % 2 == 0 else "capture"
        b.append(f'<text x="299" y="230" text-anchor="middle" style="{MONO};font-size:11.5px;font-weight:700" '
                 f'fill="{TEAL}" opacity="0">{word}<animate attributeName="opacity" values="0;0;1;1;0;0" '
                 f'keyTimes="0;{k0:.3f};{k0+0.001:.3f};{k1:.3f};{k1+0.001:.3f};1" '
                 f'dur="{total}s" repeatCount="indefinite"/></text>')

    # five engine rows, lit in turn
    for i, (n, c) in enumerate(zip(names, costs)):
        y = 96 + i * 54
        start = (1 + 2 * i) / 16.0
        stop = (3 + 2 * i) / 16.0
        b.append(f'<line x1="384" y1="198" x2="470" y2="{y+20}" stroke="{LINE}" stroke-width="1.4"/>'
                 f'<line x1="660" y1="{y+20}" x2="700" y2="198" stroke="{LINE}" stroke-width="1.4"/>')
        b.append(f'<rect x="470" y="{y}" width="190" height="40" rx="8" fill="#f8fafc" stroke="{LINE}">'
                 f'<animate attributeName="fill" values="#f8fafc;#f8fafc;#ccfbf1;#ccfbf1;#f8fafc;#f8fafc" '
                 f'keyTimes="0;{start:.3f};{start+0.001:.3f};{stop:.3f};{stop+0.001:.3f};1" '
                 f'dur="{total}s" repeatCount="indefinite"/></rect>')
        b.append(f'<text x="488" y="{y+25}" style="{FONT};font-size:13px;font-weight:600" fill="{INK}">{n}</text>')
        # the cost appears once that engine has been evaluated
        b.append(f'<text x="640" y="{y+25}" text-anchor="end" style="{MONO};font-size:13px" fill="{DIM}" opacity="0">'
                 f'cost {c}<animate attributeName="opacity" values="0;0;1;1" '
                 f'keyTimes="0;{stop:.3f};{stop+0.001:.3f};1" dur="{total}s" repeatCount="indefinite"/></text>')

    # argmin and the winner
    win = costs.index(min(costs))
    wy = 96 + win * 54
    ts = 12 / 16.0
    b.append(f'<rect x="700" y="170" width="110" height="56" rx="9" fill="#f3f6fa" stroke="{LINE}"/>'
             f'<text x="755" y="196" text-anchor="middle" style="{FONT};font-size:13px;font-weight:600" fill="{INK}">argmin</text>'
             f'<text x="755" y="213" text-anchor="middle" style="{MONO};font-size:10.5px" fill="{DIM}">+ margin</text>')
    b.append(f'<rect x="466" y="{wy-4}" width="198" height="48" rx="10" fill="none" stroke="{AMBER}" stroke-width="3" opacity="0">'
             f'<animate attributeName="opacity" values="0;0;1;1;0" keyTimes="0;{ts:.3f};{ts+0.001:.3f};0.97;1" '
             f'dur="{total}s" repeatCount="indefinite"/></rect>')
    b.append(f'<rect x="840" y="170" width="120" height="56" rx="9" fill="#fff7ed" stroke="{AMBER}" stroke-width="1.8" opacity="0.25">'
             f'<animate attributeName="opacity" values="0.25;0.25;1;1;0.25" keyTimes="0;{(14/16):.3f};{(14/16)+0.001:.3f};0.97;1" '
             f'dur="{total}s" repeatCount="indefinite"/></rect>'
             f'<text x="900" y="196" text-anchor="middle" style="{FONT};font-size:13px;font-weight:700" fill="{INK}">dispatch</text>'
             f'<text x="900" y="213" text-anchor="middle" style="{MONO};font-size:10.5px" fill="{AMBER}">→ {names[win]}</text>')
    b.append(f'<line x1="810" y1="198" x2="840" y2="198" stroke="{LINE}" stroke-width="1.4"/>')

    # the cycle counter
    for cyc in range(14):
        k0, k1 = (cyc + 1) / 16.0, (cyc + 2) / 16.0
        b.append(f'<text x="24" y="{h-30}" style="{MONO};font-size:12px" fill="{INK}" opacity="0">cycle {cyc}'
                 f'<animate attributeName="opacity" values="0;0;1;1;0;0" '
                 f'keyTimes="0;{k0:.3f};{k0+0.001:.3f};{k1:.3f};{k1+0.001:.3f};1" '
                 f'dur="{total}s" repeatCount="indefinite"/></text>')
    b.append(f'<text x="130" y="{h-30}" style="{FONT};font-size:12px" fill="{DIM}">'
             f'Costs here are illustrative; the cycle structure is the real one (tt/tile/src/rtl/mom_top.sv).</text>')
    write("dispatch_anim.svg", card(w, h, "".join(b), "How a dispatch decision is made"))


def anim_selftest():
    """The FPGA bring-up image's power-on walk: one lit LED, 0 to 7, twice."""
    w, h = 760, 230
    step = 0.25
    total = step * 16 + 1.2
    b = [f'<text x="24" y="58" style="{FONT};font-size:12.5px" fill="{DIM}">'
         f'What the board shows at power-on. One <tspan fill="{INK}" font-weight="600">lit</tspan> LED walking means '
         f'the clock, bitstream and polarity are right; one <tspan fill="{INK}" font-weight="600">dark</tspan> LED walking means polarity is inverted.</text>']
    for i in range(8):
        x = 70 + i * 82
        keys, vals = ["0"], ["0.18"]
        for p in range(2):
            on = (p * 8 + i) * step / total
            off = (p * 8 + i + 1) * step / total
            keys += [f"{on:.4f}", f"{on+0.0005:.4f}", f"{off:.4f}", f"{off+0.0005:.4f}"]
            vals += ["0.18", "1", "1", "0.18"]
        keys.append("1"); vals.append("0.18")
        b.append(f'<circle cx="{x}" cy="128" r="22" fill="#fde68a" opacity="0.18">'
                 f'<animate attributeName="opacity" values="{";".join(vals)}" keyTimes="{";".join(keys)}" '
                 f'dur="{total}s" repeatCount="indefinite"/></circle>'
                 f'<circle cx="{x}" cy="128" r="11" fill="{AMBER}" opacity="0.25">'
                 f'<animate attributeName="opacity" values="{";".join(vals)}" keyTimes="{";".join(keys)}" '
                 f'dur="{total}s" repeatCount="indefinite"/></circle>'
                 f'<text x="{x}" y="180" text-anchor="middle" style="{MONO};font-size:12px" fill="{DIM}">led[{i}]</text>')
    write("selftest_anim.svg", card(w, h, "".join(b), "FPGA bring-up: the power-on walk"), repos=[OUT[0]])


def timing_chart():
    """Setup slack per corner, from the newest REAL run in docs/timing.json."""
    d = json.loads((ROOT / "docs/timing.json").read_text())
    r = d["runs"][-1]
    cs = r["corners"]
    w, top, rh = 900, 92, 30
    h = top + len(cs) * rh + 96
    lo = min(0, min(c[1] for c in cs)); hi = max(c[1] for c in cs)
    x0, x1 = 280, 770          # bars; values get their own column at the right
    sx = lambda v: x0 + (v - lo) / (hi - lo) * (x1 - x0)
    zero = sx(0)
    b = [f'<text x="24" y="58" style="{FONT};font-size:12.5px" fill="{DIM}">'
         f'Setup slack per process corner, {escape(r["label"])}. Negative means the slowest path '
         f'misses the clock at that corner.</text>']
    b.append(f'<line x1="{zero}" y1="{top-14}" x2="{zero}" y2="{top+len(cs)*rh}" stroke="{INK}" stroke-width="1.2"/>'
             f'<text x="{zero}" y="{top-20}" text-anchor="middle" style="{MONO};font-size:11px" fill="{INK}">0 ns</text>')
    for i, (name, s, hold, vio) in enumerate(cs):
        y = top + i * rh
        col = "#dc2626" if s < 0 else TEAL
        xa, xb = (sx(s), zero) if s < 0 else (zero, sx(s))
        b.append(f'<text x="{x0-12}" y="{y+15}" text-anchor="end" style="{MONO};font-size:12px" fill="{INK}">{escape(name)}</text>'
                 f'<rect x="{xa:.1f}" y="{y+3}" width="{max(2, xb-xa):.1f}" height="17" rx="3" fill="{col}"/>'
                 f'<text x="{w-28}" y="{y+16}" text-anchor="end" '
                 f'style="{MONO};font-size:12px;font-weight:600" fill="{col}">{s:+.3f} ns</text>')
    fy = top + len(cs) * rh + 30
    b.append(f'<text x="24" y="{fy}" style="{FONT};font-size:12.5px" fill="{INK}">'
             f'Slowest path {r["critical_path_ns"]:.2f} ns → at most {r["fmax_slow_MHz"]:.2f} MHz when slow and hot. '
             f'Utilisation {r["utilisation"]*100:.1f}%. DRC {r["drc"]}, LVS {r["lvs"]}, antenna {r["antenna"]}.</text>')
    b.append(f'<text x="24" y="{fy+20}" style="{FONT};font-size:11.5px" fill="{DIM}">'
             f'From docs/timing.json, pasted from tools/timing_report.py --summary on a real run.</text>')
    write("timing.svg", card(w, h, "".join(b), "Timing, from the hardened layout"))


if __name__ == "__main__":
    anim_dispatch()
    anim_selftest()
    timing_chart()


def basys3_pins():
    """Every Basys 3 pin the bring-up image uses, from the GENERATED .xdc --
    which is itself Digilent's master file with the right lines uncommented."""
    xdc = (ROOT / "fpga/build/basys3-selftest/hydra_basys3_selftest.xdc").read_text()
    pins = re.findall(r"PACKAGE_PIN\s+(\S+).*?get_ports\s*\{?\s*([A-Za-z_]+(?:\[\d+\])?)", xdc)
    groups = {}
    for ball, port in pins:
        groups.setdefault(re.sub(r"\[\d+\]", "", port), []).append((port, ball))
    order = ["clk", "btnC", "btnU", "btnD", "btnL", "btnR", "RsRx", "RsTx", "sw", "led", "seg", "dp", "an"]
    cols = [(24, ["clk", "btnC", "btnU", "btnD", "btnL", "btnR", "RsRx", "RsTx", "seg", "dp", "an"]),
            (340, ["sw"]), (620, ["led"])]
    colour = {"sw": TEAL, "led": AMBER, "seg": VIOLET, "an": VIOLET, "dp": VIOLET}
    w, h, rh = 900, 490, 25
    b = [f'<text x="24" y="58" style="{FONT};font-size:12.5px" fill="{DIM}">'
         f'Port name → Artix-7 ball. Generated from Digilent\u2019s Basys-3-Master.xdc; nothing retyped.</text>']
    for x, names in cols:
        y = 92
        for g in names:
            for port, ball in sorted(groups.get(g, []),
                                     key=lambda pb: int(re.search(r"\d+", pb[0]).group()) if "[" in pb[0] else -1):
                c = colour.get(g, INK)
                b.append(f'<text x="{x}" y="{y}" style="{MONO};font-size:12px" fill="{c}">{escape(port)}</text>'
                         f'<text x="{x+190}" y="{y}" text-anchor="end" style="{MONO};font-size:12.5px;'
                         f'font-weight:700" fill="{INK}">{escape(ball)}</text>')
                y += rh * 0.74 if g in ("sw", "led") else rh * 0.74
    n = len(pins)
    b.append(f'<text x="24" y="{h-20}" style="{FONT};font-size:12px" fill="{DIM}">'
             f'{n} pins: clock, 5 buttons, 16 switches, 16 LEDs, 7 segments, decimal point, 4 anodes, serial in and out.</text>')
    write("basys3_pins.svg", card(w, h, "".join(b), "Basys 3 — every pin, from Digilent\u2019s file"), repos=[OUT[0]])


def basys3_display_anim():
    """The four-digit display: 'HYdr' for two seconds, then the switches as hex."""
    segs = {  # bit 0 = a ... bit 6 = g
        "H": 0x76, "Y": 0x6E, "d": 0x5E, "r": 0x50,
        "A": 0x77, "5": 0x6D, "C": 0x39, "3": 0x4F}
    frames = [("HYdr", "banner — every digit distinct"), ("A5C3", "switches = 0xA5C3")]
    total, split = 6.0, 0.4
    w, h = 700, 250
    # segment geometry for one digit, origin top-left, 60 wide, 110 tall
    G = {0: (10, 0, 40, 9), 1: (50, 8, 9, 44), 2: (50, 58, 9, 44), 3: (10, 101, 40, 9),
         4: (0, 58, 9, 44), 5: (0, 8, 9, 44), 6: (10, 50, 40, 9)}
    b = [f'<rect x="60" y="64" width="580" height="160" rx="12" fill="#111827"/>']
    for d in range(4):
        x0, y0 = 120 + d * 130, 90
        for k, (gx, gy, gw, gh) in G.items():
            vals = []
            for word, _ in frames:
                vals.append("1" if (segs[word[d]] >> k) & 1 else "0.07")
            b.append(f'<rect x="{x0+gx}" y="{y0+gy}" width="{gw}" height="{gh}" rx="3" fill="#ef4444" opacity="{vals[0]}">'
                     f'<animate attributeName="opacity" values="{vals[0]};{vals[0]};{vals[1]};{vals[1]}" '
                     f'keyTimes="0;{split:.2f};{split+0.001:.3f};1" dur="{total}s" repeatCount="indefinite"/></rect>')
    for i, (word, cap) in enumerate(frames):
        a, z = ("1", "0") if i == 0 else ("0", "1")
        b.append(f'<text x="350" y="{h-8}" text-anchor="middle" style="{FONT};font-size:12.5px" fill="{DIM}" opacity="{a}">'
                 f'{escape(cap)}<animate attributeName="opacity" values="{a};{a};{z};{z}" '
                 f'keyTimes="0;{split:.2f};{split+0.001:.3f};1" dur="{total}s" repeatCount="indefinite"/></text>')
    write("basys3_display_anim.svg", card(w, h, "".join(b), "Basys 3 display: the banner, then the switches"),
          repos=[OUT[0]])


if __name__ == "__main__":
    basys3_pins()
    basys3_display_anim()

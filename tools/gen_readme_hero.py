#!/usr/bin/env python3
"""
gen_readme_hero.py -- the README's lead figures, drawn from the repository.

  hero.svg               the chip: a floorplan with every block drawn to its
                         MEASURED cell area (docs/metrics.json), a pad ring,
                         and one animated dispatch; beside it, the sign-off
                         facts read from docs/timing.json and the proofs
                         counted from the .sby files
  tile_hero.svg          the same idea for the Tiny Tapeout tile repository
  measure_anim.svg       hardware padding filling a 64-byte block, then the
                         digest extending the measurement register
  noninterference_anim.svg  the key-vault proof: two copies, different keys,
                         identical host-visible outputs -- and what a planted
                         leak looks like

Colours are SkyWater 130's own layout layers, the ones a layout viewer
draws: metal-1 blue, metal-2 magenta, diffusion green, and gold for the
pads. Each colour means one thing everywhere: blue is the dispatcher and
timing, green is compute and verification, magenta is security, gold is
the physical chip.

Animation is CSS, not SMIL, so the SVG can honour prefers-reduced-motion;
with motion off, each figure shows its final, fully-explained state.
"""
import json, math, pathlib
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_MAIN = ROOT / "docs/img"
OUT_TILE = ROOT / "tt/tile/docs/img"

# SkyWater 130 layer palette (on the dark die) ------------------------------
SUB    = "#17202c"   # substrate
SUB2   = "#1e2938"   # core area
MET1   = "#5b9cf5"   # metal 1: dispatcher, timing
DIFF   = "#3dbb8a"   # diffusion: compute, verification
MET2   = "#e061b0"   # metal 2: security
PAD    = "#d6a93c"   # pads: the physical chip
SLATE  = "#7d8ea3"   # infrastructure
TXT    = "#eef2f7"
TXT2   = "#a9b6c6"

# The same layers, darkened to read on the white teaching cards
INK, DIM, LINE, CARD = "#111827", "#5b6576", "#d6dce5", "#ffffff"
M1D, DFD, M2D, PDD = "#2563c9", "#13865c", "#b0287f", "#a87b12"

FONT = "font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif"
MONO = "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"


CHECK = False          # --check: compare with the files instead of writing
STALE = []


def write(name, svg, dirs):
    for d in dirs:
        if CHECK:
            f = d / name
            if not f.exists() or f.read_text() != svg:
                STALE.append(str(f.relative_to(ROOT)))
            continue
        d.mkdir(parents=True, exist_ok=True)
        (d / name).write_text(svg)


def check_readme_numbers():
    """Numbers the READMEs quote in prose must match the latest harden.
    The summary table said 66.7% utilisation for a week after the run that
    measured 67.3% (found 2026-10-08)."""
    import re
    _, t, _, _, _ = data()
    util = f'{t["utilisation"]*100:.1f}%'
    worst = f'+{min(c[1] for c in t["corners"]):.2f} ns'
    bad = []
    for f in (ROOT / "README.md", ROOT / "tt/tile/README.md"):
        txt = f.read_text()
        for m in re.finditer(r"(\d\d\.\d)%\*{0,2} (?:utilisation|of the 4×4 tile)", txt):
            if m.group(1) + "%" != util:
                bad.append(f"{f.relative_to(ROOT)}: says {m.group(1)}% utilisation, latest harden {util}")
        for m in re.finditer(r"slack \*{0,2}(\+\d+\.\d\d ns)", txt):
            if m.group(1) != worst:
                bad.append(f"{f.relative_to(ROOT)}: says slack {m.group(1)}, latest harden {worst}")
    return bad


def data():
    m = json.loads((ROOT / "docs/metrics.json").read_text())
    t = json.loads((ROOT / "docs/timing.json").read_text())["runs"][-1]
    n_sby = sum(1 for f in ROOT.rglob("*.sby") if f.parent.name == "formal" and ".git" not in f.parts)
    gl = next((v["result"] for v in m["verification"] if "hardened netlist" in v["what"]), None)
    unb = sum(1 for v in m["verification"] if v["result"] == "unbounded")
    return m, t, n_sby, gl, unb


# ---------------------------------------------------------------------------
# A squarified treemap, so blocks are drawn to their measured area.
def squarify(items, x, y, w, h):
    """items: [(key, area)] sorted descending. Returns {key: (x,y,w,h)}."""
    out, items = {}, list(items)
    total = sum(a for _, a in items)
    scale = (w * h) / total
    items = [(k, a * scale) for k, a in items]

    def worst(row, side):
        s = sum(a for _, a in row)
        return max(max(side * side * a / (s * s), (s * s) / (side * side * a)) for _, a in row)

    while items:
        side = min(w, h)
        row = [items.pop(0)]
        while items and worst(row + [items[0]], side) <= worst(row, side):
            row.append(items.pop(0))
        s = sum(a for _, a in row)
        if w >= h:                       # lay the row as a column on the left
            cw = s / h; cy = y
            for k, a in row:
                ch = a / cw; out[k] = (x, cy, cw, ch); cy += ch
            x += cw; w -= cw
        else:                            # lay the row along the top
            rh = s / w; cx = x
            for k, a in row:
                rw = a / rh; out[k] = (cx, y, rw, rh); cx += rw
            y += rh; h -= rh
    return out


# ---------------------------------------------------------------------------
def hero():
    m, t, n_sby, gl, unb = data()
    W, H = 1200, 600
    eng = {e["name"]: e["um2"] for e in m["engines"]}
    blocks = [
        ("disp", "Dispatcher", m["tile"]["shared_um2"], MET1),
        ("tpu",  "Systolic array", eng["TPU"], DIFF),
        ("simd", "Vector unit", eng["SIMD"], DIFF),
        ("ntt",  "Transform engine", eng["NTT"], DIFF),
        ("sha",  "SHA-256", eng["SHA-256"], MET2),
        ("infra", "Test port + streamer", eng["JTAG"] + eng["Streamer"], SLATE),
    ]
    # die and core geometry
    dx, dy, dw, dh = 650, 40, 510, 510
    core = (dx + 46, dy + 46, dw - 92, dh - 92)
    gap = 5
    rects = squarify([(k, a) for k, _, a, _ in sorted(blocks, key=lambda b: -b[2])], *core)
    total = sum(a for _, _, a, _ in blocks)

    s = []
    s.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
             f'role="img" aria-labelledby="t d">')
    s.append('<title id="t">HYDRA-130</title>')
    s.append('<desc id="d">A floorplan of the chip with each block drawn to its measured cell area, '
             'and a work descriptor being routed by the dispatcher to the systolic array. '
             f'Timing closes at {t["period_ns"]} ns at every corner; design rules, layout versus '
             'schematic and antenna are clean.</desc>')
    s.append(f'''<style>
  .pulse {{ offset-path: path("{{PATH}}"); offset-distance: 100%; opacity: 0; }}
  .sweep {{ opacity: 0; }}
  .route {{ stroke-dashoffset: 0; }}
  .win   {{ opacity: 1; }}
  .tag   {{ opacity: 1; }}
  @media (prefers-reduced-motion: no-preference) {{
    .pulse {{ animation: travel 8s linear infinite; }}
    .sweep {{ animation: sweep 8s linear infinite; }}
    .s1 {{ animation-delay: 0s; }} .s2 {{ animation-delay: .55s; }}
    .s3 {{ animation-delay: 1.1s; }} .s4 {{ animation-delay: 1.65s; }}
    .route {{ animation: draw 8s linear infinite; }}
    .win   {{ animation: win 8s linear infinite; }}
    .tag   {{ animation: win 8s linear infinite; }}
  }}
  @keyframes travel {{ 0% {{ offset-distance: 0%; opacity: 0 }} 2% {{ opacity: 1 }}
                       22% {{ offset-distance: 100%; opacity: 1 }} 24%,100% {{ offset-distance: 100%; opacity: 0 }} }}
  @keyframes sweep  {{ 0%,24% {{ opacity: 0 }} 26% {{ opacity: .85 }} 31% {{ opacity: .85 }} 33%,100% {{ opacity: 0 }} }}
  @keyframes draw   {{ 0%,52% {{ stroke-dashoffset: 400 }} 62%,90% {{ stroke-dashoffset: 0 }} 96%,100% {{ stroke-dashoffset: 400 }} }}
  @keyframes win    {{ 0%,60% {{ opacity: 0 }} 65%,90% {{ opacity: 1 }} 96%,100% {{ opacity: 0 }} }}
</style>''')
    s.append('<defs>'
             f'<pattern id="rows" width="8" height="7" patternUnits="userSpaceOnUse">'
             f'<rect width="8" height="3" fill="#ffffff" opacity="0.06"/></pattern>'
             f'<pattern id="grid" width="24" height="24" patternUnits="userSpaceOnUse">'
             f'<path d="M24 0H0V24" fill="none" stroke="#ffffff" stroke-opacity="0.035"/></pattern>'
             '</defs>')
    s.append(f'<rect width="{W}" height="{H}" rx="18" fill="{SUB}"/>')
    s.append(f'<rect width="{W}" height="{H}" rx="18" fill="url(#grid)"/>')

    # ---- die: seal ring, pads, core ------------------------------------------
    s.append(f'<rect x="{dx}" y="{dy}" width="{dw}" height="{dh}" rx="6" fill="none" stroke="{PAD}" stroke-opacity=".35" stroke-width="2"/>')
    pads, pitch = [], 34
    n = int((dw - 60) // pitch)
    for i in range(n):
        p = dx + 30 + i * pitch + (dw - 60 - (n - 1) * pitch) / 2 - 7
        pads += [(p, dy + 10, 14, 18), (p, dy + dh - 28, 14, 18)]
        q = dy + 30 + i * pitch + (dh - 60 - (n - 1) * pitch) / 2 - 7
        pads += [(dx + 10, q, 18, 14), (dx + dw - 28, q, 18, 14)]
    for (x, y, w, h) in pads:
        s.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w}" height="{h}" rx="2" fill="{PAD}" opacity=".85"/>')
    cx, cy, cw, ch = core
    s.append(f'<rect x="{cx-6}" y="{cy-6}" width="{cw+12}" height="{ch+12}" rx="4" fill="{SUB2}"/>')

    centre = {}
    for k, label, area, col in blocks:
        x, y, w, h = rects[k]
        x, y, w, h = x + gap / 2, y + gap / 2, w - gap, h - gap
        centre[k] = (x + w / 2, y + h / 2, x, y, w, h)
        s.append(f'<g><title>{escape(label)}: {area:,} µm² of standard cells</title>'
                 f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="3" '
                 f'fill="{col}" fill-opacity=".20" stroke="{col}" stroke-opacity=".9" stroke-width="1.3"/>'
                 f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="3" fill="url(#rows)"/>')
        if w > 70 and h > 40:
            fs = 15 if w > 130 else 12.5
            s.append(f'<text x="{x+10:.1f}" y="{y+22:.1f}" style="{FONT};font-size:{fs}px;font-weight:650" fill="{TXT}">{escape(label)}</text>'
                     f'<text x="{x+10:.1f}" y="{y+22+fs+3:.1f}" style="{FONT};font-size:{fs-2}px" fill="{TXT2}">{area/1000:,.0f}k µm²</text>')
        s.append('</g>')
    # the sweep: the cost engine considers each engine in turn
    order = ["simd", "tpu", "ntt", "sha"]
    for i, k in enumerate(order):
        _, _, x, y, w, h = centre[k]
        s.append(f'<rect class="sweep s{i+1}" x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="3" '
                 f'fill="none" stroke="{TXT}" stroke-width="2.4"/>')
    # the chosen route: dispatcher -> systolic array
    ax, ay = centre["disp"][:2]
    bx, by = centre["tpu"][:2]
    route = f"M{ax:.1f},{ay:.1f} H{(ax+bx)/2:.1f} V{by:.1f} H{bx:.1f}"
    s.append(f'<path class="route" d="{route}" fill="none" stroke="{MET2}" stroke-width="3.2" '
             f'stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="400"/>')
    _, _, x, y, w, h = centre["tpu"]
    s.append(f'<rect class="win" x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="3" '
             f'fill="{DIFF}" fill-opacity=".28" stroke="{DIFF}" stroke-width="2.6"/>')

    # ---- the title, and the wire from it into the chip -----------------------
    s.append(f'<text x="56" y="150" style="{FONT};font-size:78px;font-weight:800;letter-spacing:-2px" fill="{TXT}">HYDRA-130</text>')
    # the underline is a metal-2 wire that runs to a pad and on into the dispatcher
    pad_y = min((p for p in pads if abs(p[0] - (dx + 10)) < 1), key=lambda p: abs(p[1] + 7 - 176))
    py = pad_y[1] + 7
    wire = f"M58,176 H{dx-30} V{py:.1f} H{dx+19} M{dx+28},{py:.1f} H{cx-6} V{ay:.1f} H{ax:.1f}"
    pulse_path = f"M58,176 H{dx-30} V{py:.1f} H{cx-6} V{ay:.1f} H{ax:.1f}"
    s.append(f'<path d="{wire}" fill="none" stroke="{MET2}" stroke-opacity=".75" stroke-width="2.4" stroke-linejoin="round"/>')
    s.append(f'<circle class="pulse" r="6.5" fill="{TXT}" stroke="{MET2}" stroke-width="3"/>')

    s.append(f'<text x="58" y="222" style="{FONT};font-size:23px" fill="{TXT2}">A dispatcher chip that measures its own engines,</text>')
    s.append(f'<text x="58" y="252" style="{FONT};font-size:23px" fill="{TXT2}">open source, for SkyWater&#8217;s 130 nm process.</text>')

    # ---- what is established, each in the colour of what it is about ----------
    worst = min(c[1] for c in t["corners"])
    clean = t["drc"] == 0 and t["lvs"] == 0 and t["antenna"] == 0
    rows = [
        (MET1, "Timing", f'{t["period_ns"]} ns, all nine corners, +{worst:.2f} ns'),
        (PAD,  "Layout", "design rules, LVS and antenna all clean" if clean else "sign-off NOT clean"),
        (DIFF, "Gate level", f'{gl.replace(" / ", " of ")} tests on the hardened netlist' if gl else "gate-level simulation pending"),
        (DIFF, "Proofs", f'{n_sby} modules proved, {unb} results unbounded'),
        (MET2, "Root of trust", "write-only keys, images measured in hardware"),
    ]
    y = 330
    for col, k, v in rows:
        s.append(f'<rect x="58" y="{y-13}" width="14" height="14" rx="2" fill="{col}"/>'
                 f'<text x="86" y="{y}" style="{FONT};font-size:19px;font-weight:650" fill="{TXT}">{escape(k)}</text>'
                 f'<text x="226" y="{y}" style="{FONT};font-size:17px" fill="{TXT2}">{escape(v)}</text>')
        y += 42
    s.append(f'<text x="58" y="{H-54}" style="{FONT};font-size:14px" fill="{TXT2}" opacity=".85">'
             f'Blocks drawn to measured cell area, {total/1e6:.2f} mm² in all.</text>'
             f'<text x="58" y="{H-32}" style="{FONT};font-size:14px" fill="{TXT2}" opacity=".85">'
             f'Key vault, mailbox and measurement register are not yet measured.</text>')
    _, _, x, y2, w, h = centre["tpu"]
    s.append(f'<text class="tag" x="{dx+dw/2}" y="{dy+dh+30}" text-anchor="middle" style="{FONT};font-size:15px" fill="{TXT2}">'
             f'an 8×8×8 matrix multiply goes to the systolic array</text>')
    s.append('</svg>\n')
    svg = "".join(s).replace("{PATH}", pulse_path)
    write("hero.svg", svg, [OUT_MAIN])


# ---------------------------------------------------------------------------
def tile_hero():
    """The Tiny Tapeout tile: pins around a 4x4 tile, the dispatcher inside."""
    m, t, n_sby, gl, unb = data()
    W, H = 1200, 560
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">tt_um_hydra_mom</title>',
         '<desc id="d">The Tiny Tapeout tile: a descriptor shifted in on the input pins, five engines '
         'costed one after another by a single shared cost engine, and the winner reported on the output pins.</desc>']
    s.append('''<style>
  .bit { opacity: 1; } .cost { opacity: 1; } .out { opacity: 1; } .hl { opacity: 0; }
  @media (prefers-reduced-motion: no-preference) {
    .bit  { animation: bit 7s linear infinite; }
    .hl   { animation: hl 7s linear infinite; }
    .out  { animation: out 7s linear infinite; }
  }
  @keyframes bit { 0% { opacity: .15 } 4% { opacity: 1 } 30% { opacity: 1 } 34%,100% { opacity: .15 } }
  @keyframes hl  { 0%,34% { opacity: 0 } 36% { opacity: 1 } 44% { opacity: 1 } 46%,100% { opacity: 0 } }
  @keyframes out { 0%,74% { opacity: .15 } 78%,94% { opacity: 1 } 98%,100% { opacity: .15 } }
</style>''')
    s.append('<defs><pattern id="rows" width="8" height="7" patternUnits="userSpaceOnUse">'
             '<rect width="8" height="3" fill="#ffffff" opacity="0.06"/></pattern></defs>')
    s.append(f'<rect width="{W}" height="{H}" rx="18" fill="{SUB}"/>')
    # the 4x4 tile
    tx, ty, tw, th = 640, 70, 400, 400
    for i in range(1, 4):
        s.append(f'<line x1="{tx+i*tw/4}" y1="{ty}" x2="{tx+i*tw/4}" y2="{ty+th}" stroke="#ffffff" stroke-opacity=".06"/>'
                 f'<line x1="{tx}" y1="{ty+i*th/4}" x2="{tx+tw}" y2="{ty+i*th/4}" stroke="#ffffff" stroke-opacity=".06"/>')
    s.append(f'<rect x="{tx}" y="{ty}" width="{tw}" height="{th}" rx="4" fill="{SUB2}" fill-opacity=".6" stroke="{PAD}" stroke-opacity=".6" stroke-width="2"/>')
    # pins: 8 in on the left, 8 out on the right
    for i in range(8):
        y = ty + 40 + i * 44
        d = 0.05 * i
        s.append(f'<rect class="bit" style="animation-delay:{d:.2f}s" x="{tx-34}" y="{y-6}" width="22" height="12" rx="2" fill="{PAD}"/>'
                 f'<text x="{tx-44}" y="{y+5}" text-anchor="end" style="{MONO};font-size:13px" fill="{TXT2}">ui[{i}]</text>')
        s.append(f'<rect class="out" x="{tx+tw+12}" y="{y-6}" width="22" height="12" rx="2" fill="{PAD}"/>'
                 f'<text x="{tx+tw+44}" y="{y+5}" style="{MONO};font-size:13px" fill="{TXT2}">uo[{i}]</text>')
    # pipeline inside: shift register -> features -> one shared cost engine -> select
    stages = [("Descriptor", "128 bits, shifted in", MET1), ("Features", "work shape", MET1),
              ("Cost engine", "one, shared", MET1), ("Select", "cheapest + margin", MET1)]
    for i, (a, b, c) in enumerate(stages):
        x, y = tx + 30, ty + 30 + i * 90
        s.append(f'<rect x="{x}" y="{y}" width="200" height="66" rx="4" fill="{c}" fill-opacity=".18" stroke="{c}" stroke-width="1.3"/>'
                 f'<rect x="{x}" y="{y}" width="200" height="66" rx="4" fill="url(#rows)"/>'
                 f'<text x="{x+12}" y="{y+28}" style="{FONT};font-size:16px;font-weight:650" fill="{TXT}">{a}</text>'
                 f'<text x="{x+12}" y="{y+49}" style="{FONT};font-size:13px" fill="{TXT2}">{b}</text>')
        if i < 3:
            s.append(f'<path d="M{x+100},{y+66} V{y+90}" stroke="{MET1}" stroke-width="2"/>')
    # five engines, costed in turn
    names = ["CPU", "SIMD", "TPU", "NTT", "Crypto"]
    for i, nme in enumerate(names):
        x, y = tx + 262, ty + 30 + i * 70
        win = nme == "TPU"
        s.append(f'<rect x="{x}" y="{y}" width="110" height="50" rx="4" fill="{DIFF}" fill-opacity="{".30" if win else ".12"}" '
                 f'stroke="{DIFF}" stroke-opacity="{1 if win else .55}" stroke-width="{2 if win else 1.2}"/>'
                 f'<text x="{x+55}" y="{y+31}" text-anchor="middle" style="{FONT};font-size:15px;font-weight:650" fill="{TXT}">{nme}</text>'
                 f'<rect class="hl" style="animation-delay:{i*0.6:.1f}s" x="{x}" y="{y}" width="110" height="50" rx="4" fill="none" stroke="{TXT}" stroke-width="2.4"/>'
                 f'<path d="M{tx+230},{ty+30+2*90+33} L{x},{y+25}" stroke="{MET1}" stroke-opacity=".35" stroke-width="1.2"/>')
    # left text
    worst = min(c[1] for c in t["corners"])
    s.append(f'<text x="56" y="132" style="{FONT};font-size:54px;font-weight:800;letter-spacing:-1.5px" fill="{TXT}">tt_um_hydra_mom</text>')
    s.append(f'<text x="58" y="180" style="{FONT};font-size:20px" fill="{TXT2}">A work dispatcher on a 4×4 Tiny Tapeout tile.</text>')
    s.append(f'<text x="58" y="208" style="{FONT};font-size:20px" fill="{TXT2}">It costs five engines, picks the cheapest.</text>')
    rows = [
        (MET1, "Timing", f'{t["period_ns"]} ns, every corner (+{worst:.2f} ns)'),
        (PAD,  "Sign-off", "DRC, LVS, antenna clean" if (t["drc"] == 0 and t["lvs"] == 0 and t["antenna"] == 0) else "NOT clean"),
        (PAD,  "Utilisation", f'{t["utilisation"]*100:.1f}% of the tile'),
        (DIFF, "Gate level", f'{gl.replace(" / ", " of ")} tests on the hardened netlist' if gl else "pending"),
    ]
    y = 290
    for col, k, v in rows:
        s.append(f'<rect x="58" y="{y-13}" width="14" height="14" rx="2" fill="{col}"/>'
                 f'<text x="86" y="{y}" style="{FONT};font-size:19px;font-weight:650" fill="{TXT}">{k}</text>'
                 f'<text x="216" y="{y}" style="{FONT};font-size:18px" fill="{TXT2}">{escape(v)}</text>')
        y += 42
    s.append(f'<text x="{tx+tw/2}" y="{ty+th+50}" text-anchor="middle" style="{FONT};font-size:14px" fill="{TXT2}">'
             f'Not to scale: the pipeline as drawn in tt/tile/src/rtl/mom_top.sv</text>')
    s.append('</svg>\n')
    write("tile_hero.svg", "".join(s), [OUT_TILE])


# ---------------------------------------------------------------------------
def measure_anim():
    """Hardware padding of a 50-byte image, then the PCR extend."""
    W, H = 980, 460
    n = 50                               # message bytes in the example
    bits = n * 8
    length = bits.to_bytes(8, "big")
    T = 10.0                             # seconds per loop
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">Measuring an image</title>',
         f'<desc id="d">Software sends {n} image bytes. The hardware writes the 0x80 marker, five zero bytes '
         f'and the length, {bits} bits, then hashes the block and extends the measurement register.</desc>']
    css = ['.c { opacity: 1; } .flow { opacity: 1; } .bar { transform: scaleX(1); } .newpcr { opacity: 1; }']
    css.append('@media (prefers-reduced-motion: no-preference) {')
    css.append(f'  .c {{ animation-duration: {T}s; animation-timing-function: linear; animation-iteration-count: infinite; }}')
    css.append(f'  .flow {{ animation: flow {T}s linear infinite; }}')
    css.append(f'  .bar {{ animation: bar {T}s linear infinite; transform-box: fill-box; transform-origin: left; }}')
    css.append(f'  .newpcr {{ animation: newpcr {T}s linear infinite; }}')
    css.append('}')
    css.append('@keyframes flow { 0%,56% { opacity: 0 } 60%,92% { opacity: 1 } 97%,100% { opacity: 0 } }')
    css.append('@keyframes bar  { 0%,58% { transform: scaleX(0) } 72%,92% { transform: scaleX(1) } 97%,100% { transform: scaleX(0) } }')
    css.append('@keyframes newpcr { 0%,74% { opacity: 0 } 80%,92% { opacity: 1 } 97%,100% { opacity: 0 } }')
    style_at = len(s); s.append(None)
    s.append(f'<rect x="1" y="1" width="{W-2}" height="{H-2}" rx="14" fill="{CARD}" stroke="{LINE}"/>')
    s.append(f'<text x="28" y="40" style="{FONT};font-size:19px;font-weight:700" fill="{INK}">Measuring an image: software sends bytes, hardware pads</text>')
    s.append(f'<text x="28" y="64" style="{FONT};font-size:13.5px" fill="{DIM}">'
             f'One 64-byte SHA-256 block for a {n}-byte image. Software cannot write the marker, the zeros or the length, '
             f'so it cannot choose what is hashed.</text>')
    # the block: 8 x 8 bytes
    gx, gy, c = 28, 96, 38
    cell_kf = []
    for i in range(64):
        x, y = gx + (i % 8) * (c + 4), gy + (i // 8) * (c + 4)
        if i < n:
            col, lab, fg, delay = M1D, "", "#ffffff", i * 0.055
        elif i == n:
            col, lab, fg, delay = M2D, "80", "#ffffff", n * 0.055 + 0.35
        elif i < 56:
            col, lab, fg, delay = "#e7ebf0", "00", DIM, n * 0.055 + 0.6 + (i - n - 1) * 0.07
        else:
            col, lab, fg, delay = PDD, f"{length[i-56]:02x}", "#ffffff", n * 0.055 + 1.0 + (i - 56) * 0.09
        start = 100 * delay / T
        cell_kf.append(f'@keyframes c{i} {{ 0%,{start:.2f}% {{ opacity: .08 }} {start+1.2:.2f}%,92% {{ opacity: 1 }} 97%,100% {{ opacity: .08 }} }}'
                       f' .c{i} {{ animation-name: c{i}; }}')
        s.append(f'<g class="c c{i}">'
                 f'<rect x="{x}" y="{y}" width="{c}" height="{c}" rx="4" fill="{col}" fill-opacity="{0.9 if i < n else 1}"/>'
                 + (f'<text x="{x+c/2}" y="{y+c/2+5}" text-anchor="middle" style="{MONO};font-size:13px;font-weight:700" fill="{fg}">{lab}</text>' if lab else "")
                 + '</g>')
    # legend, in the right-hand column
    lx, ly = 420, 112
    for k, (col, txt) in enumerate([(M1D, f"{n} image bytes, sent by software"),
                                    (M2D, "the 0x80 marker"),
                                    ("#cfd6df", "zero bytes"),
                                    (PDD, f"the length, {bits} bits, as 8 bytes")]):
        y = ly + k * 26
        s.append(f'<rect x="{lx}" y="{y-11}" width="14" height="14" rx="3" fill="{col}"/>'
                 f'<text x="{lx+24}" y="{y+1}" style="{FONT};font-size:14px" fill="{INK}">{escape(txt)}</text>')
    s.append(f'<text x="{lx}" y="{ly+4*26+6}" style="{FONT};font-size:13px" fill="{DIM}">Everything not blue is written by hardware, from the count</text>'
             f'<text x="{lx}" y="{ly+4*26+24}" style="{FONT};font-size:13px" fill="{DIM}">of bytes it actually accepted.</text>')
    # the hash and the register
    hx, hy = 420, 268
    s.append(f'<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
             f'<path d="M0,0 L10,5 L0,10 z" fill="{INK}"/></marker></defs>')
    s.append(f'<g class="flow"><path d="M{gx+8*(c+4)+6},{hy+40} H{hx-6}" stroke="{INK}" stroke-width="2" marker-end="url(#ah)"/></g>')
    s.append(f'<rect x="{hx}" y="{hy}" width="170" height="84" rx="10" fill="#f3f6fa" stroke="{LINE}"/>'
             f'<text x="{hx+85}" y="{hy+32}" text-anchor="middle" style="{FONT};font-size:16px;font-weight:700" fill="{INK}">SHA-256</text>'
             f'<text x="{hx+85}" y="{hy+52}" text-anchor="middle" style="{FONT};font-size:12.5px" fill="{DIM}">64 rounds</text>'
             f'<rect x="{hx+20}" y="{hy+64}" width="130" height="8" rx="4" fill="#e7ebf0"/>'
             f'<rect class="bar" x="{hx+20}" y="{hy+64}" width="130" height="8" rx="4" fill="{DFD}"/>')
    s.append(f'<g class="flow"><path d="M{hx+170},{hy+42} H{hx+222}" stroke="{INK}" stroke-width="2" marker-end="url(#ah)"/>'
             f'<text x="{hx+176}" y="{hy+32}" style="{MONO};font-size:11.5px" fill="{DIM}">digest</text></g>')
    px, py = hx + 228, hy - 10
    s.append(f'<rect x="{px}" y="{py}" width="300" height="140" rx="10" fill="#fdf4fa" stroke="{M2D}" stroke-opacity=".5"/>'
             f'<text x="{px+18}" y="{py+30}" style="{FONT};font-size:16px;font-weight:700" fill="{INK}">Measurement register</text>'
             f'<text x="{px+18}" y="{py+58}" style="{MONO};font-size:13px" fill="{INK}">PCR ← SHA-256(</text>'
             f'<text x="{px+40}" y="{py+78}" style="{MONO};font-size:13px" fill="{INK}">PCR ‖ digest )</text>'
             f'<text x="{px+18}" y="{py+106}" style="{FONT};font-size:12.5px" fill="{DIM}">No write port. Software never</text>'
             f'<text x="{px+18}" y="{py+123}" style="{FONT};font-size:12.5px" fill="{DIM}">handles the digest.</text>'
             f'<text class="newpcr" x="{px+282}" y="{py+30}" text-anchor="end" style="{FONT};font-size:13px;font-weight:700" fill="{M2D}">extended</text>')
    css.append('@media (prefers-reduced-motion: no-preference) {\n' + "\n".join(cell_kf) + '\n}')
    s[style_at] = '<style>' + "\n".join(css) + '</style>'
    s.append('</svg>\n')
    write("measure_anim.svg", "".join(s), [OUT_MAIN])


# ---------------------------------------------------------------------------
def noninterference_anim():
    """Two vault copies, different keys, identical outputs -- then a leak."""
    import random
    rng = random.Random(7)
    W, H = 980, 470
    T = 12.0
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">Proving the key vault cannot leak</title>',
         '<desc id="d">Two copies of the key vault receive identical commands but hold different keys. '
         'Their host-visible outputs are identical on every cycle, which is what the proof shows for all '
         'keys and all cycles. With a planted leak the outputs differ and the proof fails.</desc>']
    css = ['.ok { opacity: 1; } .bad { opacity: 0; }',
           '@media (prefers-reduced-motion: no-preference) {',
           f'  .ok  {{ animation: ok {T}s linear infinite; }}',
           f'  .bad {{ animation: bad {T}s linear infinite; }}',
           f'  .k0 {{ animation: k0 1.6s steps(1) infinite; }} .k1 {{ animation: k1 1.6s steps(1) infinite; }}',
           '}',
           '@keyframes ok  { 0%,58% { opacity: 1 } 60%,96% { opacity: 0 } 98%,100% { opacity: 1 } }',
           '@keyframes bad { 0%,58% { opacity: 0 } 60%,96% { opacity: 1 } 98%,100% { opacity: 0 } }',
           '@keyframes k0  { 0% { opacity: 1 } 50% { opacity: .18 } }',
           '@keyframes k1  { 0% { opacity: .18 } 50% { opacity: 1 } }']
    s.append('<style>' + "\n".join(css) + '</style>')
    s.append(f'<rect x="1" y="1" width="{W-2}" height="{H-2}" rx="14" fill="{CARD}" stroke="{LINE}"/>')
    s.append(f'<text x="28" y="40" style="{FONT};font-size:19px;font-weight:700" fill="{INK}">Proving the key vault cannot leak</text>')
    s.append(f'<text x="28" y="64" style="{FONT};font-size:13.5px" fill="{DIM}">Two copies, the same commands, different keys. If any key bit reached the host port, '
             f'the copies would disagree on some cycle.</text>')
    # shared command stream in the middle
    s.append(f'<rect x="400" y="96" width="180" height="58" rx="10" fill="#f3f6fa" stroke="{LINE}"/>'
             f'<text x="490" y="121" text-anchor="middle" style="{FONT};font-size:14.5px;font-weight:700" fill="{INK}">same commands</text>'
             f'<text x="490" y="141" text-anchor="middle" style="{FONT};font-size:12px" fill="{DIM}">write, seal, read status</text>'
             f'<path d="M400,125 H300 V176" fill="none" stroke="{INK}" stroke-width="1.6"/>'
             f'<path d="M580,125 H680 V176" fill="none" stroke="{INK}" stroke-width="1.6"/>')
    outs = {}
    for side, x0 in (("A", 60), ("B", 560)):
        s.append(f'<rect x="{x0}" y="180" width="360" height="160" rx="12" fill="#fdf4fa" stroke="{M2D}" stroke-opacity=".45"/>'
                 f'<text x="{x0+18}" y="206" style="{FONT};font-size:15px;font-weight:700" fill="{INK}">vault, copy {side}</text>'
                 f'<text x="{x0+342}" y="206" text-anchor="end" style="{FONT};font-size:12px" fill="{DIM}">keys chosen freely by the solver</text>')
        for slot in range(4):
            y = 224 + slot * 26
            s.append(f'<text x="{x0+18}" y="{y+13}" style="{MONO};font-size:11.5px" fill="{DIM}">slot {slot}</text>')
            for b in range(20):
                cls = "k0" if rng.random() < 0.5 else "k1"
                d = rng.random() * 1.6
                s.append(f'<rect class="{cls}" style="animation-delay:-{d:.2f}s" x="{x0+70+b*13.5}" y="{y}" width="11" height="16" rx="2" fill="{M2D}"/>')
        outs[side] = x0
    # host-visible outputs
    for side, x0 in outs.items():
        s.append(f'<path d="M{x0+180},340 V368" stroke="{INK}" stroke-width="1.6"/>'
                 f'<rect x="{x0+70}" y="370" width="220" height="44" rx="8" fill="#f3f6fa" stroke="{LINE}"/>'
                 f'<text x="{x0+86}" y="396" style="{FONT};font-size:12px" fill="{DIM}">host port</text>'
                 f'<text class="ok" x="{x0+276}" y="397" text-anchor="end" style="{MONO};font-size:15px;font-weight:700" fill="{INK}">0x00080403</text>')
    # the planted leak: a key bit wired to copy A's status word
    s.append(f'<path class="bad" d="M{outs["A"]+75.5},240 V250 H40 V392 H{outs["A"]+70}" fill="none" '
             f'stroke="#b91c1c" stroke-width="2.2" stroke-dasharray="5 4"/>')
    s.append(f'<text class="bad" x="{outs["A"]+276}" y="397" text-anchor="end" style="{MONO};font-size:15px;font-weight:700" fill="#b91c1c">0x00080407</text>'
             f'<text class="bad" x="{outs["B"]+276}" y="397" text-anchor="end" style="{MONO};font-size:15px;font-weight:700" fill="#b91c1c">0x00080403</text>')
    s.append(f'<text x="490" y="352" text-anchor="middle" style="{FONT};font-size:11.5px" fill="{DIM}">'
             f'status word: words per key, slots, sealed, filled</text>')
    # verdict in the middle
    s.append(f'<g class="ok"><circle cx="490" cy="392" r="20" fill="{DFD}"/>'
             f'<text x="490" y="399" text-anchor="middle" style="{FONT};font-size:20px;font-weight:800" fill="#ffffff">=</text>'
             f'<text x="490" y="446" text-anchor="middle" style="{FONT};font-size:13px" fill="{INK}">identical on every cycle, for every key: proved unbounded at 4 × 256-bit slots</text></g>')
    s.append(f'<g class="bad"><circle cx="490" cy="392" r="20" fill="#b91c1c"/>'
             f'<text x="490" y="399" text-anchor="middle" style="{FONT};font-size:20px;font-weight:800" fill="#ffffff">≠</text>'
             f'<text x="490" y="446" text-anchor="middle" style="{FONT};font-size:13px" fill="#b91c1c">a planted leak, one key bit on the status word: the proof fails and shows the cycle</text></g>')
    s.append('</svg>\n')
    write("noninterference_anim.svg", "".join(s), [OUT_MAIN])


def main():
    import sys
    global CHECK
    CHECK = "--check" in sys.argv
    hero()
    tile_hero()
    measure_anim()
    noninterference_anim()
    if not CHECK:
        print("gen_readme_hero: hero.svg, tile_hero.svg, measure_anim.svg, noninterference_anim.svg")
        return
    bad = check_readme_numbers()
    for f in STALE:
        bad.append(f"{f} is out of date with the repository's data -- run: make readme-art")
    if bad:
        print("\n".join("readme-check: " + b for b in bad)); sys.exit(1)
    print("readme-check: lead figures current; utilisation and slack match the latest harden")


if __name__ == "__main__":
    main()

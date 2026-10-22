"""
atlas_site.py -- the Silicon Atlas: the project page, built from the repository.

Called by tools/gen_site.py (make site / make site-check). Everything on the
page is read from a file that defines it:

  docs/atlas/atlas.yaml     blocks, where they sit, what they connect to, traces
  docs/atlas/cards.yaml     what each block does, in words, with citations
  docs/atlas/derived.json   which builds contain each block (from the compiler)
  docs/atlas/traces/*.json  recorded runs of passing tests
  docs/atlas/physical.json  placed cells mapped to RTL by netlist names
  docs/metrics.json, docs/timing.json, tt/tile/info.yaml, the tile's RTL

The page is one self-contained file. No content delivery network, no fonts
to fetch, no build step: it opens from disk and from GitHub Pages alike. The
HTML is complete without JavaScript (every card, table and text version of
a figure is in the markup); the script adds tabs, the build switcher, the
layout canvas and the trace player.
"""
import hashlib, html as H, json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import atlas_theme as T          # noqa: E402
import atlas_tile                # noqa: E402

ATLAS = ROOT / "docs/atlas"
REPO = "Normansrule/hydra-skywater130"
GH = "https://github.com"

# kinds of evidence a trace can be, shown on every player
LABELS = {
    "Recorded RTL Trace": "Replayed from a value change dump of a passing RTL simulation.",
    "Gate-Level Trace": "Replayed from a simulation of the hardened gate-level netlist.",
    "Model Simulation": "Computed by an executable model that is itself checked against the RTL.",
    "Hardware Capture": "Measured on a real board or chip.",
    "Concept": "An explanation of intended behaviour; not evidence.",
    "Recorded Tool Output": "Read from the logs and reports of one identified tool run.",
}


# Icons, drawn once in one stroke weight and referenced by <use>. The role
# marks pair every colour with a shape, so colour is never the only cue.
ICONS = """<svg xmlns="http://www.w3.org/2000/svg" style="display:none" aria-hidden="true">
<symbol id="i-signal" viewBox="0 0 16 16"><path d="M3 4l6 4-6 4z" fill="currentColor"/><path d="M10 8h4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></symbol>
<symbol id="i-control" viewBox="0 0 16 16"><path d="M8 2l6 6-6 6-6-6z" fill="currentColor"/></symbol>
<symbol id="i-compute" viewBox="0 0 16 16"><rect x="3" y="3" width="10" height="10" rx="1.5" fill="currentColor"/></symbol>
<symbol id="i-memory" viewBox="0 0 16 16"><rect x="2.5" y="3" width="11" height="2.4" rx="1" fill="currentColor"/><rect x="2.5" y="6.8" width="11" height="2.4" rx="1" fill="currentColor"/><rect x="2.5" y="10.6" width="11" height="2.4" rx="1" fill="currentColor"/></symbol>
<symbol id="i-secure" viewBox="0 0 16 16"><path d="M8 1.8l5 2v4.1c0 3-2.1 5.1-5 6.3-2.9-1.2-5-3.3-5-6.3V3.8z" fill="currentColor"/></symbol>
<symbol id="i-check" viewBox="0 0 16 16"><path d="M3 8.5l3.2 3L13 4.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></symbol>
<symbol id="i-cross" viewBox="0 0 16 16"><path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></symbol>
<symbol id="i-play" viewBox="0 0 16 16"><path d="M4.5 3v10l8.5-5z" fill="currentColor"/></symbol>
<symbol id="i-pause" viewBox="0 0 16 16"><rect x="4" y="3" width="2.8" height="10" rx="1" fill="currentColor"/><rect x="9.2" y="3" width="2.8" height="10" rx="1" fill="currentColor"/></symbol>
<symbol id="i-first" viewBox="0 0 16 16"><rect x="3" y="3" width="2.2" height="10" rx="1" fill="currentColor"/><path d="M13 3v10L6.5 8z" fill="currentColor"/></symbol>
<symbol id="i-prev" viewBox="0 0 16 16"><path d="M8 3v10L2 8zM14.5 3v10l-6-5z" fill="currentColor"/></symbol>
<symbol id="i-next" viewBox="0 0 16 16"><path d="M8 3v10l6-5zM1.5 3v10l6-5z" fill="currentColor"/></symbol>
<symbol id="i-mark" viewBox="0 0 24 24"><path d="M12 2v20M2 12h20" stroke="currentColor" stroke-width="1.6"/><rect x="6.5" y="6.5" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.6"/><rect x="10" y="10" width="4" height="4" fill="currentColor"/></symbol>
<symbol id="i-chip" viewBox="0 0 24 24"><rect x="5" y="5" width="14" height="14" rx="2.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><rect x="9.5" y="9.5" width="5" height="5" rx="1" fill="currentColor"/></symbol>
</svg>"""


def ico(name, cls="ico", label=None):
    a = f' role="img" aria-label="{label}"' if label else ' aria-hidden="true"'
    return f'<svg class="{cls}"{a}><use href="#i-{name}"/></svg>'


def esc(s):
    return H.escape(str(s), quote=True)


def load():
    import yaml
    spec = yaml.safe_load((ATLAS / "atlas.yaml").read_text())
    cards_f = ATLAS / "cards.yaml"
    cards = yaml.safe_load(cards_f.read_text()) if cards_f.exists() else {}
    derived = json.loads((ATLAS / "derived.json").read_text())
    traces = {}
    for t in spec.get("traces", []):
        f = ATLAS / "traces" / f"{t['id']}.json"
        if f.exists():
            traces[t["id"]] = json.loads(f.read_text())
    phys_f = ATLAS / "physical.json"
    phys = json.loads(phys_f.read_text()) if phys_f.exists() else None
    flow_f = ATLAS / "flow.json"
    flow = json.loads(flow_f.read_text()) if flow_f.exists() else None
    timing = json.loads((ROOT / "docs/timing.json").read_text())["runs"]
    die = {}
    for k in ("die", "die-gl"):
        f = ATLAS / f"{k}.json"
        if f.exists():
            die[k] = json.loads(f.read_text())
            die[k + ".bin"] = (ATLAS / die[k]["bin"]["file"]).read_bytes()
    fp_f = ATLAS / "fpga.json"
    die["fpga"] = json.loads(fp_f.read_text()) if fp_f.exists() else None
    return spec, cards, derived, traces, phys, flow, timing, die


# ---------------------------------------------------------------------------
# freshness: the derived data must describe the files as they are now
# ---------------------------------------------------------------------------
def stale_sources(derived, traces, phys, die=None):
    def sha(p):
        f = ROOT / p
        return hashlib.sha256(f.read_bytes()).hexdigest() if f.exists() else None
    bad = []
    die = die or {}
    if "die" in die:
        d = die["die"]
        if hashlib.sha256(die["die.bin"]).hexdigest() != d["bin"]["sha256"]:
            bad.append("die.bin is not the file die.json describes (tools/atlas_die.py layout)")
        if phys and d["run"]["netlist_sha256"] != phys["run"]["netlist_sha256"]:
            bad.append("die.json and physical.json are from different hardened runs")
    if "die-gl" in die:
        g = die["die-gl"]
        if hashlib.sha256(die["die-gl.bin"]).hexdigest() != g["bin"]["sha256"]:
            bad.append("die-gl.bin is not the file die-gl.json describes (tools/atlas_die.py gl)")
        if "die" in die and g["netlist_sha256"] != die["die"]["run"]["netlist_sha256"]:
            bad.append("die-gl.json was recorded on a different netlist from die.json")
        for f, k in (("tt/tile/src/project.v", "project_v_sha256"), (g["test"].split("::")[0], "test_sha256"),
                     ("tt/tile/test/tb.v", "tb_sha256")):
            if sha(f) != g[k]:
                bad.append(f"die-gl.json: {f} changed since the gate-level run was recorded (tools/atlas_die.py gl)")
    fp = die.get("fpga")
    if fp:
        for f, h in fp["sources"].items():
            if sha(f) != h:
                bad.append(f"fpga.json: {f} changed since make memboard was recorded (tools/atlas_fpga.py)")
    for name in ("sans", "mono"):
        fm = ATLAS / "fonts/fonts.json"
        if fm.exists():
            m = json.loads(fm.read_text())["faces"][name]
            if sha(f"docs/atlas/fonts/{m['file']}") != m["sha256"]:
                bad.append(f"docs/atlas/fonts/{m['file']} is not the file fonts.json describes")
    for bid, b in derived["builds"].items():
        for f, h in b["sources"].items():
            if sha(f) != h:
                bad.append(f"derived.json: build {bid}: {f} changed (make atlas)")
    for f, info in derived["files"].items():
        if sha(f) != info["sha256"]:
            bad.append(f"derived.json: {f} changed (make atlas)")
    for tid, t in traces.items():
        for f, h in t["sources"].items():
            if sha(f) != h:
                bad.append(f"trace {tid}: {f} changed since it was recorded (make atlas-traces)")
    if (ROOT / "docs/img/layout.png").exists() and sha("docs/img/layout.png") != sha("docs/site/media/layout.png"):
        bad.append("docs/site/media/layout.png is not docs/img/layout.png (make atlas-physical copies it)")
    if phys and sha("tt/tile/src/project.v") != phys["run"]["project_v_sha256"]:
        bad.append("physical.json: project.v changed since the layout was mapped; re-map a run of the new netlist")
    return sorted(set(bad))


# ---------------------------------------------------------------------------
# which builds contain each block
# ---------------------------------------------------------------------------
BUILD_ORDER = ["tile", "chip", "sim-systile", "sim-systile-mem", "sim-systile-two", "sim-systile-gpu",
               "sim-systile-abi", "sim-systile-cpu"]


def build_list(derived):
    ids = [b for b in BUILD_ORDER if b in derived["builds"]]
    ids += sorted(b for b in derived["builds"] if b not in ids)
    return ids


def present(block, build):
    if block.get("concept"):
        return block["id"] == "host"
    return any(m in build["modules"] for m in block.get("modules", []))


def availability(spec, derived):
    out = {}
    for b in spec["blocks"]:
        out[b["id"]] = [bid for bid in build_list(derived) if present(b, derived["builds"][bid])]
    return out


def short_name(bid):
    return {"tile": "Tiny Tapeout tile", "chip": "OpenFrame chip"}.get(bid, bid.replace("sim-", "sim: ").replace("fpga-", "FPGA: "))


def permalink(derived, path, module=None):
    info = derived["files"].get(path)
    if not info:
        return None
    url = f"{GH}/{info['repo']}/blob/{info['commit']}/{info['path']}"
    lines = derived.get("module_lines", {}).get(module) if module else None
    if lines and lines.get("file") == path:
        url += f"#L{lines['first']}-L{lines['last']}"
    return url


# ---------------------------------------------------------------------------
# logical diagrams: orthogonal edges in the channels between rows and columns
# ---------------------------------------------------------------------------
BW, BH, GX, GY, PAD = 136, 52, 44, 40, 24


def role_mark(role, x, y, size=11):
    """The role's shape, drawn in SVG (the same shapes as the icon set)."""
    k = size / 16
    shapes = {"signal": "M3 4l6 4-6 4zM10 7h4v2h-4z", "control": "M8 2l6 6-6 6-6-6z",
              "compute": "M3 3h10v10H3z", "memory": "M2.5 3h11v2.4h-11zM2.5 6.8h11v2.4h-11zM2.5 10.6h11v2.4h-11z",
              "secure": "M8 1.8l5 2v4.1c0 3-2.1 5.1-5 6.3-2.9-1.2-5-3.3-5-6.3V3.8z"}
    return (f'<path class="sym" transform="translate({x} {y}) scale({k:.4f})" d="{shapes[role]}"/>')


def logical_svg(spec, build, title):
    blocks = [b for b in spec["blocks"] if present(b, build)]
    if not blocks:
        return ""
    cols = sorted({b["col"] for b in blocks})
    rows = sorted({b["row"] for b in blocks})
    ci = {c: i for i, c in enumerate(cols)}
    ri = {r: i for i, r in enumerate(rows)}
    pos = {}
    for b in blocks:
        x = PAD + ci[b["col"]] * (BW + GX)
        y = PAD + ri[b["row"]] * (BH + GY)
        if b["id"] in pos.values():
            pass
        pos[b["id"]] = (x, y)
    # two blocks in one cell would overlap: refuse rather than draw it
    seen = {}
    for b in blocks:
        k = pos[b["id"]]
        if k in seen:
            raise SystemExit(f"atlas_site: {b['id']} and {seen[k]} share a grid cell in {build['name']}")
        seen[k] = b["id"]
    W = PAD * 2 + len(cols) * BW + (len(cols) - 1) * GX
    Hh = PAD * 2 + len(rows) * BH + (len(rows) - 1) * GY
    ids = {b["id"] for b in blocks}
    edges = [e for e in spec["edges"] if e[0] in ids and e[1] in ids]
    role = {b["id"]: b["role"] for b in blocks}
    out = [f'<svg class="logical" viewBox="0 0 {W} {Hh}" role="img" '
           f'aria-label="{esc(title)}. Logical view: positions are not die locations. '
           f'The blocks and connections are listed as text below." xmlns="http://www.w3.org/2000/svg">',
           '<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
           'orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="context-stroke"/></marker></defs>']
    # channel lanes: count edges per channel to spread them apart
    lane_use = {}

    def lane(key):
        n = lane_use.get(key, 0)
        lane_use[key] = n + 1
        return n

    for a, b, label in edges:
        ax, ay = pos[a]
        bx, by = pos[b]
        cls = f"edge r-{role[a]}"
        if ax < bx:                                  # forward: right side of a to left side of b
            x1, y1 = ax + BW, ay + BH / 2
            x2, y2 = bx, by + BH / 2
            gx1 = ax + BW + GX / 2 + (lane(("g", ax)) % 5 - 2) * 4
            if ay == by and bx - ax == BW + GX:
                d = f"M{x1} {y1}H{x2}"
            elif bx - ax == BW + GX:
                d = f"M{x1} {y1}H{gx1}V{y2}H{x2}"
            else:
                # along the channel above b's row (or below a's) to the gap left of b
                cy = (min(ay, by) - GY / 2 if ay != by else ay - GY / 2) + (lane(("c", ay, by)) % 5 - 2) * 4
                if cy < 4:
                    cy = max(ay, by) + BH + GY / 2
                gx2 = bx - GX / 2 + (lane(("g", bx)) % 5 - 2) * 4
                d = f"M{x1} {y1}H{gx1}V{cy}H{gx2}V{y2}H{x2}"
        elif ax > bx:                                # backward: leave from the bottom, along the channel below
            x1, y1 = ax + BW / 2, ay + BH
            x2, y2 = bx + BW / 2, by + BH
            cy = max(ay, by) + BH + GY / 2 + (lane(("b", max(ay, by))) % 5 - 2) * 4
            d = f"M{x1} {y1}V{cy}H{x2}V{y2}"
        else:                                        # same column
            x = ax + BW / 2 + (lane(("v", ax)) % 3 - 1) * 10
            if ay < by:
                d = f"M{x} {ay + BH}V{by}"
            else:
                d = f"M{x} {ay}V{by + BH}"
        out.append(f'<path class="{cls}" data-a="{a}" data-b="{b}" d="{d}" marker-end="url(#ah)">'
                   f'<title>{esc(label)}</title></path>')
    for blk in blocks:
        x, y = pos[blk["id"]]
        out.append(f'<g class="node r-{blk["role"]}" data-id="{blk["id"]}" tabindex="0" role="button" '
                   f'aria-label="{esc(blk["label"])}: {esc(blk["sub"])}. Open its card.">'
                   f'<rect x="{x}" y="{y}" width="{BW}" height="{BH}" rx="8"/>'
                   f'{role_mark(blk["role"], x + 11, y + 11)}'
                   f'<text class="nl" x="{x + 26}" y="{y + 21}">{esc(blk["label"])}</text>'
                   f'<text class="ns" x="{x + 12}" y="{y + 39}">{esc(blk["sub"])}</text></g>')
    out.append("</svg>")
    return "\n".join(out)


def logical_figure(build_id, title):
    """The logical view of one named build as a standalone README figure,
    with @token colours (atlas_theme.variants writes both themes). Blocks
    come from the compiler's instance tree, so a block that is not
    instantiated in that build cannot be drawn."""
    import yaml
    spec = yaml.safe_load((ATLAS / "atlas.yaml").read_text())
    derived = json.loads((ATLAS / "derived.json").read_text())
    b = derived["builds"][build_id]
    svg = logical_svg(spec, b, title)
    m = re.match(r'<svg class="logical" viewBox="0 0 (\d+) (\d+)"', svg)
    w, h = int(m.group(1)), int(m.group(2))
    sans, mono = T.FONT.split(":", 1)[1], T.MONO.split(":", 1)[1]
    style = ("<style>"
             f".node .nl{{font:600 13px {sans};fill:@ink}}.node .ns{{font:11px {mono};fill:@ink2}}"
             ".node rect{stroke-width:1.4}.edge{fill:none;stroke-width:1.5;stroke:@dim}"
             + "".join(f".r-{r} rect{{fill:@{r}_t;stroke:@{r}}}.r-{r} .sym{{fill:@{r};font:13px {sans}}}"
                       for r in T.ROLES)
             + f".cap{{font:12px {mono};fill:@dim}}</style>")
    body = svg.split(">", 1)[1].rsplit("</svg>", 1)[0]
    body = body.replace('fill="context-stroke"', 'fill="@dim"')
    H2 = h + 30
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {H2}" width="{w}" height="{H2}" role="img" '
            f'aria-label="{esc(title)}. Logical view, not a floorplan.">{style}'
            f'<rect width="{w}" height="{H2}" rx="12" fill="@surface" stroke="@line"/>{body}'
            f'<text class="cap" x="{PAD}" y="{H2 - 12}">{esc(title)} · logical view, not die positions · '
            f'blocks read from the compiled build</text></svg>\n')


def logical_text(spec, build):
    blocks = [b for b in spec["blocks"] if present(b, build)]
    ids = {b["id"] for b in blocks}
    lab = {b["id"]: b["label"] for b in spec["blocks"]}
    items = "".join(f"<li><b>{esc(b['label'])}</b>: {esc(b['sub'])}</li>" for b in blocks)
    conns = "".join(f"<li>{esc(lab[a])} to {esc(lab[b])}: {esc(l)}</li>"
                    for a, b, l in spec["edges"] if a in ids and b in ids)
    absent = [b for b in spec["blocks"] if b["id"] not in ids and not b.get("concept")]
    miss = ", ".join(esc(b["label"]) for b in absent)
    return (f'<details class="textalt"><summary>This view as text</summary>'
            f'<h4>Blocks</h4><ul>{items}</ul><h4>Connections</h4><ul>{conns}</ul>'
            f'<p><b>Not in this build:</b> {miss}.</p></details>')


# ---------------------------------------------------------------------------
# the tile's pins, drawn from info.yaml and the wrapper
# ---------------------------------------------------------------------------
def pin_svg(tp):
    pins = tp["pins"]
    W, Hh = 860, 460
    cx, cy, cw, ch = 300, 24, 260, 300
    s = [f'<svg class="pins" viewBox="0 0 {W} {Hh}" role="img" xmlns="http://www.w3.org/2000/svg" '
         f'aria-label="The tile\'s 24 pins: SPI on ui[2:0], status on uo, tag and margin on uio. Listed in the table below.">',
         f'<rect class="die" x="{cx}" y="{cy}" width="{cw}" height="{ch}" rx="10"/>',
         f'<text class="dl" x="{cx + cw / 2}" y="{cy + 28}" text-anchor="middle">{esc(tp["top"])}</text>',
         f'<text class="ds" x="{cx + cw / 2}" y="{cy + 48}" text-anchor="middle">{esc(tp["tiles"])} tiles · '
         f'{tp["clock_hz"] / 1e6:.2f} MHz</text>']
    groups = [("ui", "input", cx, -1), ("uo", "output", cx + cw, 1)]
    for g, d, x0, side in groups:
        for i in range(8):
            p = next(p for p in pins if p["pin"] == f"{g}[{i}]")
            y = cy + 70 + i * 28
            used = p["rtl"] != "unused"
            cls = "pin used" if used else "pin unused"
            x1 = x0 + side * 34
            s.append(f'<line class="{cls}" x1="{x0}" y1="{y}" x2="{x1}" y2="{y}"/>')
            s.append(f'<rect class="{cls}" x="{x1 - 6 if side > 0 else x1 - 6}" y="{y - 6}" width="12" height="12" rx="2"/>')
            name = p["desc"].split(" - ")[0] if p["desc"] else "unused"
            tx = x1 + side * 14
            anchor = "start" if side > 0 else "end"
            s.append(f'<text class="pn" x="{tx}" y="{y + 4}" text-anchor="{anchor}">{esc(p["pin"])}  {esc(name)}</text>')
    # uio along the bottom
    for i in range(8):
        p = next(p for p in pins if p["pin"] == f"uio[{i}]")
        x = cx + 22 + i * 31
        y0 = cy + ch
        s.append(f'<line class="pin used" x1="{x}" y1="{y0}" x2="{x}" y2="{y0 + 26}"/>')
        s.append(f'<rect class="pin used" x="{x - 6}" y="{y0 + 26}" width="12" height="12" rx="2"/>')
        name = p["desc"].split(" - ")[0]
        s.append(f'<text class="pn" transform="translate({x + 4} {y0 + 46}) rotate(60)">{esc(p["pin"])} {esc(name)}</text>')
    s.append(f'<text class="ds" x="{cx + cw / 2}" y="{cy + ch - 14}" text-anchor="middle">uio_oe = {esc(tp["uio_oe"])}: all outputs</text>')
    s.append("</svg>")
    return "\n".join(s)


# ---------------------------------------------------------------------------
def fmt_ns(v):
    return f"{v:+.2f} ns"


def status_cards(timing, metrics, derived):
    t = timing[-1]
    worst = min(c[1] for c in t["corners"])
    hold = min(c[2] for c in t["corners"])
    gl = next((v["result"] for v in metrics["verification"] if v.get("target") == "tile-gl"), "not run")
    plans = [b for b in derived["builds"] if b.startswith("fpga-")]
    pnr = [b["plan"] for b in metrics["boards"]]
    return [
        ("tile", f"Tiny Tapeout tile, {t['version']}",
         "Hardened: sign-off record from one LibreLane run. Not fabricated, not tested silicon.",
         [("Timing", f"met at all {len(t['corners'])} corners at {t['period_ns']} ns, setup {fmt_ns(worst)}, hold {hold:+.3f} ns"),
          ("Sign-off", f"DRC {t['drc']}, LVS {t['lvs']}, antenna {t['antenna']}"),
          ("Open", f"{t['slew_violations']:,} slow-corner slew warnings, capacitance {t['cap_violations']}"),
          ("Gate level", f"{gl} tile tests on that run's netlist"),
          ("Source", t["source"])]),
        ("chip", "SkyWater 130 OpenFrame chip",
         "Simulated through its pads. Never hardened: no layout, no timing, no DRC or LVS.",
         [("Top", "scheduler, pad multiplexer, reset synchroniser, SPI"),
          ("Engines", "CPU, GPU and TPU slots exist only in system-tile simulation builds, not in the chip top"),
          ("Check", "make sky130 (through the pads), make lint (Verilator -Wall, 0 warnings)"),
          ("Next", "move the engines into this top, turn the CPU memory into SRAM, then harden")]),
        ("fpga", "FPGA images",
         f"{len(plans)} build plans. Place and route recorded for {len(pnr)} ECP5 images. No image has run on a board.",
         [("Built", ", ".join(pnr)),
          ("Host paths", "serial on every image; serial and JTAG on Basys 3 only"),
          ("Board runs", "none yet"),
          ("Next", "the ULX3S scheduler image on a real board; the Basys 3 image through Vivado")]),
    ]


def render(metrics):
    spec, cards, derived, traces, phys, flow, timing, die = load()
    problems = stale_sources(derived, traces, phys, die)
    avail = availability(spec, derived)
    tp = atlas_tile.pins()
    rg = atlas_tile.registers()
    builds = build_list(derived)
    bname = {b: derived["builds"][b]["name"] for b in builds}
    blk = {b["id"]: b for b in spec["blocks"]}

    # ---- logical views, one per build -----------------------------------
    views = []
    for bid in builds:
        b = derived["builds"][bid]
        svg = logical_svg(spec, b, b["name"])
        views.append(f'<figure class="lview" data-build="{bid}" hidden>'
                     f'<div class="scroll">{svg}</div>'
                     f'<figcaption>{esc(b["name"])} &mdash; {len(b["modules"])} modules elaborated '
                     f'by <code>{esc(b["how"])}</code>.</figcaption>{logical_text(spec, b)}</figure>')
    build_opts = "".join(f'<option value="{b}"{" selected" if b == "tile" else ""}>{esc(bname[b])}</option>'
                         for b in builds)

    # ---- block cards -------------------------------------------------------
    card_html = []
    for b in spec["blocks"]:
        c = cards.get(b["id"], {})
        av = avail[b["id"]]
        mod = (b.get("modules") or [None])[0]
        link = permalink(derived, b["file"], mod) if b.get("file") else None
        badges = "".join(f'<li title="{esc(bname[x])}">{esc(short_name(x))}</li>' for x in av if not x.startswith("fpga-"))
        fp = [x[5:] for x in av if x.startswith("fpga-")]
        if fp:
            badges += f'<li>FPGA: {esc(", ".join(fp))}</li>'
        if not av:
            badges = '<li class="none">In no build: checked IP, not connected</li>'
        if b.get("concept"):
            badges = '<li class="none">Software, not hardware</li>'

        def io(rows):
            if not rows:
                return "<p class='muted'>See the source.</p>"
            return "<table class='io'><thead><tr><th>Port</th><th class='num'>Width</th><th>Meaning</th></tr></thead><tbody>" + "".join(
                f"<tr><td><code>{esc(r.get('name'))}</code></td><td class='num'>{esc(r.get('width', ''))}</td>"
                f"<td>{esc(r.get('desc', ''))}</td></tr>" for r in rows) + "</tbody></table>"

        ev = "".join(f"<li><code>{esc(e['target'])}</code> {esc(e.get('what', ''))}</li>"
                     for e in c.get("evidence", []))
        ex = c.get("expert", {})
        exp_parts = []
        for k, title in (("params", "Parameters"), ("registers", "Registers"), ("timing", "Timing"),
                         ("memory_map", "Memory layout"), ("assumptions", "Assumptions")):
            v = ex.get(k)
            if not v:
                continue
            if isinstance(v, list):
                lis = "".join(f"<li>{esc(x if isinstance(x, str) else ', '.join(f'{a}: {b2}' for a, b2 in x.items()))}</li>" for x in v)
                exp_parts.append(f"<h5>{title}</h5><ul>{lis}</ul>")
            else:
                exp_parts.append(f"<h5>{title}</h5><p>{esc(v)}</p>")
        sb = c.get("security_bounds")
        if sb:
            exp_parts.append(f"<h5>Security bounds</h5><p><b>Claimed:</b> {esc(sb.get('claimed', ''))}</p>"
                             f"<p><b>Not claimed:</b> {esc(sb.get('not_claimed', ''))}</p>")
        cites = "".join(f"<li>{esc(x)}</li>" for x in c.get("citations", [])[:40])
        at = cards.get("_cited_at", {})
        if cites and not c.get("_cites_current") and b.get("file") in at.get("changed_since", []):
            cites = (f"<li class='warnline'>These line numbers are to commit {esc(at['repo'])}; "
                     f"{esc(b['file'])} has changed since. The permalink above opens the current file.</li>" + cites)
        card_html.append(f'''
<article class="card r-{b["role"]}" id="card-{b["id"]}" data-id="{b["id"]}" data-role="{b["role"]}"
  data-builds="{" ".join(av)}">
  <header>{ico(b["role"])}
    <h3>{esc(b["label"])}</h3><span class="role">{esc(b["role"])}</span></header>
  <p class="job">{esc(c.get("job", b["sub"]))}</p>
  <ul class="avail" aria-label="Builds that contain it">{badges}</ul>
  <details class="more"><summary>Inputs, outputs, clock, example, failure, evidence</summary>
    <dl>
      <dt>Inputs</dt><dd>{io(c.get("inputs"))}</dd>
      <dt>Outputs</dt><dd>{io(c.get("outputs"))}</dd>
      <dt>Clock and reset</dt><dd>{esc(c.get("clock_reset", "See the source."))}</dd>
      <dt>Example</dt><dd>{esc(c.get("example", ""))}</dd>
      <dt>Failure and back-pressure</dt><dd>{esc(c.get("failure", ""))}</dd>
      <dt>Source</dt><dd>{f'<a href="{esc(link)}">{esc(b["file"])}</a>' if link else f"<code>{esc(b.get('file', ''))}</code>"}
        {f'<code>{esc(", ".join(b.get("modules", [])))}</code>' if b.get("modules") else ""}</dd>
      <dt>Evidence</dt><dd>{f"<ul>{ev}</ul>" if ev else "<p class='muted'>No check names this block.</p>"}</dd>
    </dl>
    {f'<details class="expert"><summary>Expert view: widths, registers, timing, assumptions</summary>{"".join(exp_parts)}<h5>Citations</h5><ul class="cites">{cites}</ul></details>' if exp_parts or cites else ""}
  </details>
</article>''')

    # ---- registers and pins -----------------------------------------------
    pin_rows = "".join(f"<tr><td><code>{esc(p['pin'])}</code></td><td>{esc(p['dir'])}</td>"
                       f"<td><code>{esc(p['rtl'])}</code></td><td>{esc(p['desc'])}</td></tr>"
                       for p in tp["pins"])
    reg_rows = "".join(f"<tr><td><code>0x{r['addr']:02X}</code></td><td>{esc(r['name'])}</td>"
                       f"<td class='num'>{r['len']}</td><td>{esc(r['access'])}</td><td>{esc(r['desc'])}</td></tr>"
                       for r in rg["registers"])
    status_bits = "".join(f"<tr><td class='num'>{f['msb']}{'' if f['msb'] == f['lsb'] else ':' + str(f['lsb'])}</td>"
                          f"<td><code>{esc(f['name'])}</code></td></tr>" for f in rg["status"])
    result_bits = "".join(f"<tr><td class='num'>{f['msb']}:{f['lsb']}</td><td><code>{esc(f['name'])}</code></td></tr>"
                          for f in rg["result"])

    # ---- evidence ---------------------------------------------------------
    ver_rows = "".join(f"<tr><td>{esc(v['what'])}</td><td class='num'>{esc(v['result'])}</td>"
                       f"<td>{esc(v['kind'])}</td><td><code>make {esc(v['target'])}</code></td></tr>"
                       for v in metrics["verification"])
    pend = "".join(f"<li>{esc(p)}</li>" for p in metrics["pending"])
    contra = cards.get("_contradictions", [])
    contra_rows = "".join(
        f"<tr><td>{esc(c.get('claim', c.get('doc', '')))}</td><td>{esc(c.get('rtl', ''))}</td>"
        f"<td>{esc(c.get('status', 'reported; the RTL and its comments are unchanged'))}</td></tr>" for c in contra)
    trace_rows = "".join(
        f"<tr><td>{esc(t['title'])}</td><td>{esc(t['label'])}</td><td><code>{esc(t['test'])}</code></td>"
        f"<td>{esc(t['result'])}</td><td><code>{esc(t.get('tile_commit', t.get('repo_commit', ''))[:10])}</code></td></tr>"
        for t in traces.values())

    # ---- data for the script ----------------------------------------------
    data = {
        "builds": {b: {"name": bname[b], "short": short_name(b), "modules": derived["builds"][b]["modules"]} for b in builds},
        "status_bits": [[f["name"], f["msb"], f["lsb"]] for f in rg["status"]],
        "result_bits": [[f["name"], f["msb"], f["lsb"]] for f in rg["result"]],
        "blocks": {b["id"]: {"label": b["label"], "role": b["role"]} for b in spec["blocks"]},
        "traces": traces, "labels": LABELS,
        "roles": list(T.ROLES), "symbols": T.SYMBOL,
        "die": ({k: v for k, v in die["die"].items() if k not in ("_comment",)} if "die" in die else None),
        "diegl": ({k: v for k, v in die["die-gl"].items() if k != "_comment"} if "die-gl" in die else None),
        "diepal": T.DIE, "modname": MODNAME, "dispatch": list(DISPATCH),
        "fpga": die.get("fpga"), "fpgaphases": fpga_phases(die.get("fpga"), rg),
        "regs": {r["addr"]: r["name"] for r in rg["registers"]},
        "reglen": {r["addr"]: r["len"] for r in rg["registers"]},
        "flow": flow,
    }
    blob = json.dumps(data, separators=(",", ":"), sort_keys=True).replace("</", "<\\/")

    st = status_cards(timing, metrics, derived)
    st_html = "".join(
        f'<section class="target t-{k}"><h3><span class="dot" aria-hidden="true"></span>{esc(title)}</h3><p>{esc(sub)}</p><dl>' +
        "".join(f"<dt>{esc(a)}</dt><dd>{esc(b2)}</dd>" for a, b2 in rows) + "</dl></section>"
        for k, title, sub, rows in st)

    cx = traces.get("crossover")
    tour = tour_steps(cx)
    t_last = timing[-1]
    facts = die_facts(die, traces)
    bignums, marquee = big_numbers(facts, die.get('fpga'), metrics, timing)
    match = phys and next((r for r in timing if r.get("slew_violations") == phys["metrics"].get("design__max_slew_violation__count")
                           and abs(r.get("utilisation", -1) - (phys["metrics"].get("design__instance__utilization") or -2)) < 1e-6), None)
    die_ver = match["version"] if match else "latest"
    import base64
    b64 = lambda b: base64.b64encode(b).decode()
    fonts = ""
    fm = ATLAS / "fonts/fonts.json"
    if fm.exists():
        fj = json.loads(fm.read_text())["faces"]
        fonts = "".join(
            f'@font-face{{font-family:"{fam}";src:url(data:font/woff;base64,{b64((ATLAS / "fonts" / fj[k]["file"]).read_bytes())}) '
            f'format("woff");font-weight:100 800;font-stretch:{st};font-display:swap}}'
            for k, fam, st in (("sans", "Ubuntu Sans", "75% 100%"), ("mono", "Ubuntu Sans Mono", "100%")))
    stale_note = ("" if not problems else
                  '<div class="callout warn" role="status"><b>Generated data is behind the sources.</b> ' +
                  "; ".join(esc(p) for p in problems[:6]) + "</div>")

    return PAGE.format(
        css=CSS, js=JS + DIE_JS + FPGA_JS + NUM_JS, data=blob, light=T.css_vars(T.LIGHT) + ";--grain:url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='220' height='220'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix values='0 0 0 0 .1 0 0 0 0 .08 0 0 0 0 .02 0 0 0 .09 0'/%3E%3C/filter%3E%3Crect width='220' height='220' filter='url(%23n)'/%3E%3C/svg%3E\")",
        dark=T.css_vars(T.DARK) + ";--grain:none", fonts=fonts,
        story=story_html(facts, die_ver, str(tp["tiles"]).replace("x", "×")), die_text=die_text(facts, die),
        die_bin=b64(die["die.bin"]) if "die" in die else "", diegl_bin=b64(die["die-gl.bin"]) if "die-gl" in die else "",
        die_ver=esc(die_ver), bignums=bignums, marquee=marquee, fpga_plan=esc((die.get('fpga') or {}).get('plan', '')),
        fpga_text=fpga_text(die.get('fpga'), fpga_phases(die.get('fpga'), rg)),
        status=st_html, tour=tour, views="".join(views), build_opts=build_opts,
        cards="".join(card_html), pin_svg=pin_svg(tp), pin_rows=pin_rows, reg_rows=reg_rows,
        status_bits=status_bits, result_bits=result_bits, ver_rows=ver_rows, pend=pend,
        contra_rows=contra_rows or "<tr><td colspan=3>None recorded.</td></tr>",
        trace_rows=trace_rows, labels="".join(f"<li><b>{esc(k)}</b>: {esc(v)}</li>" for k, v in LABELS.items()),
        tile_ver=esc(t_last["version"]), period=t_last["period_ns"],
        clock_mhz=f"{tp['clock_hz'] / 1e6:.2f}", tiles=esc(tp["tiles"]), stale=stale_note,
        frame=esc(rg["frame"]), phys_note=phys_note(phys, timing), flow=flow_html(flow),
        repo=REPO, n_blocks=len(spec["blocks"]), n_builds=len(builds), n_traces=len(traces),
        videos=videos_html(), icons=ICONS, hero_fig=hero_figure(cx),
        i_signal=ico("signal"), i_control=ico("control"), i_compute=ico("compute"), i_memory=ico("memory"),
        i_secure=ico("secure"),
        cited_repo=esc(cards.get("_cited_at", {}).get("repo", "")), cited_tile=esc(cards.get("_cited_at", {}).get("tile", "")),
    ), problems


def videos_html():
    """Short captioned films of two traces (tools/gen_readme_gifs.py), with
    posters; they never play on their own."""
    media = ROOT / "docs/site/media"
    figs = []
    for name in ("dispatch", "array"):
        man = media / f"{name}.json"
        if not man.exists():
            continue
        alt = json.loads(man.read_text())["alt"]
        figs.append(f'<figure class="film"><video controls preload="none" playsinline poster="media/{name}.poster.png" '
                    f'aria-label="{esc(alt)}"><source src="media/{name}.webm" type="video/webm">'
                    f'<track kind="captions" src="media/{name}.vtt" srclang="en" label="English" default></video>'
                    f'<figcaption><span class="kind">Recorded RTL Trace</span> {esc(alt)}. Captions on; the frames are '
                    f'drawn from the recorded trace.</figcaption></figure>')
    if not figs:
        return ""
    return ('<h3 style="margin-top:22px">Short films</h3><p class="muted">The same recordings as captioned video, for '
            'reading without the controls above. They start only when you press play.</p><div class="grid2">'
            + "".join(figs) + "</div>")


def hero_figure(cx):
    """The 8x8x8 decision of the recorded crossover trace, drawn as the page's
    opening picture: every engine's cost, the refused ones marked, the winner
    filled. Real numbers from the trace; nothing typed."""
    if not cx:
        return ""
    sel = [e for e in cx["events"] if e["k"] == "select"]
    s = sel[1] if len(sel) > 1 else sel[0]
    names = {"ENG_CPU": "CPU", "ENG_SIMD": "Vector unit", "ENG_TPU": "Systolic array", "ENG_NTT": "Butterflies",
             "ENG_CRYPTO": "Crypto slot"}
    refused = "cannot do this operation or data type"
    costs = [r["cost"] for r in s["rows"] if r["why"] != refused]
    mx = max(costs)
    W, row = 520, 54
    H = 40 + row * len(s["rows"]) + 10
    out = [f'<svg class="decision" viewBox="0 0 {W} {H}" role="img" aria-label="One recorded decision: '
           + "; ".join(f"{names.get(r['name'], r['name'])} " + ("refused" if r["why"] == refused else f"cost {r['cost']}")
                       for r in s["rows"]) + '.">',
           '<defs><pattern id="dots" width="16" height="16" patternUnits="userSpaceOnUse">'
           '<circle cx="1" cy="1" r="1" fill="var(--line)"/></pattern></defs>',
           f'<rect width="{W}" height="{H}" fill="url(#dots)" opacity=".7"/>',
           f'<text class="s" x="0" y="20">Recorded decision, cycle {s["c"]} of test_roofline_crossover</text>']
    y = 40
    for r in s["rows"]:
        nm = names.get(r["name"], r["name"])
        out.append(f'<text class="t" x="0" y="{y + 20}">{esc(nm)}</text>')
        x0, wmax = 150, W - 150 - 70
        if r["why"] == refused:
            out.append(f'<rect class="base" x="{x0}" y="{y + 7}" width="{wmax}" height="18" rx="9"/>'
                       f'<path class="no" transform="translate({x0 + 8} {y + 8}) scale(1)" d="M4 4l8 8M12 4l-8 8" '
                       f'stroke="var(--danger)" stroke-width="2.2" stroke-linecap="round"/>'
                       f'<text class="s" x="{x0 + 30}" y="{y + 21}">cannot run GEMM on INT8</text>')
        else:
            w = max(8, wmax * r["cost"] / mx)
            win = " win" if r["chosen"] else ""
            ei = ["ENG_CPU", "ENG_SIMD", "ENG_TPU"].index(r["name"]) if r["name"] in ("ENG_CPU", "ENG_SIMD", "ENG_TPU") else 0
            out.append(f'<rect class="base" x="{x0}" y="{y + 7}" width="{wmax}" height="18" rx="9"/>'
                       f'<rect class="bar e{ei}{win}" x="{x0}" y="{y + 7}" width="{w:.1f}" height="18" rx="9"/>'
                       f'<text class="v" x="{x0 + wmax + 10}" y="{y + 21}">{r["cost"]:,}</text>')
        y += row
    out.append("</svg>")
    win = next(r for r in s["rows"] if r["chosen"])
    return (f'<figure>{"".join(out)}<figcaption>An 8×8×8 INT8 matrix multiply: the lowest cost wins, here '
            f'{esc(names.get(win["name"], win["name"]))} by a margin of {s["margin"]}. Two engines are refused '
            f'before any cost is compared. <a href="#demos">Replay it</a>.</figcaption></figure>')


def tour_steps(cx):
    """The four-step tour, with numbers from the recorded crossover trace."""
    if not cx:
        return ""
    ev = cx["events"]
    sel = [e for e in ev if e["k"] == "select"]
    cal = [e for e in ev if e["k"] == "cal"]
    desc = [e for e in ev if e["k"] == "desc"]
    s2 = sel[1] if len(sel) > 1 else sel[0]
    d2 = desc[1] if len(desc) > 1 else desc[0]

    def nm(n):
        return {"ENG_CPU": "CPU", "ENG_SIMD": "vector unit", "ENG_TPU": "systolic array", "ENG_NTT": "butterflies",
                "ENG_CRYPTO": "crypto slot"}.get(n, n)
    costs = ", ".join(f"{nm(r['name'])} {r['cost']}" for r in s2["rows"] if r["why"] != "cannot do this operation or data type")
    rej = ", ".join(nm(r["name"]) for r in s2["rows"] if r["why"] == "cannot do this operation or data type")
    c = cal[-1] if cal else None
    steps = [
        ("1", "A job arrives", f"A 128-bit descriptor over SPI: {d2['op'].replace('OPC_', '')} on "
         f"{d2['dtype'].replace('DT_', '')}, {d2['m']}×{d2['n']}×{d2['kk']}.", d2["c"]),
        ("2", "Every engine is costed", f"One shared cost engine walks the rows, two cycles each: {costs}. "
         f"Refused before any cost is compared: {rej} cannot do this operation.", s2["c"] - 9),
        ("3", "The cheapest wins a tag", f"The {nm(next(r['name'] for r in s2['rows'] if r['chosen']))} wins "
         f"by a margin of {s2['margin']}; the scoreboard hands out tag {next(e['tag'] for e in ev if e['k'] == 'tag' and e['c'] >= s2['c'])}.", s2["c"]),
        ("4", "It measures and corrects", (f"The host reports completion; measured {c['meas']} cycles against "
         f"{c['pred']} predicted, so {nm(c['name'])}'s factor moves {c['k_cur']} → {c['k_next']} (64 = exact)."
         if c else "Completion moves that engine's factor toward the measurement."), c["c"] if c else 0),
    ]
    return "".join(
        f'<li><button class="tourstep" data-trace="crossover" data-cycle="{cyc}">'
        f'<span class="n">{n}</span><span class="tt">{esc(t)}</span><span class="td">{esc(d)}</span></button></li>'
        for n, t, d, cyc in steps)


def phys_note(phys, timing):
    if not phys:
        return ('<p class="callout warn"><b>Blocked by missing evidence.</b> No hardened run of the current '
                '<code>project.v</code> has been mapped. Run <code>make atlas-physical RUN=…</code>.</p>')
    m = phys["metrics"]
    match = next((r for r in timing if abs(r.get("utilisation", -1) - (m.get("design__instance__utilization") or -2)) < 1e-6
                  and r.get("slew_violations") == m.get("design__max_slew_violation__count")), None)
    which = (f"the <b>{esc(match['version'])}</b> harden recorded in <code>docs/timing.json</code>" if match else
             "a harden <b>not yet recorded</b> in <code>docs/timing.json</code>; its own metrics are quoted")
    lad = phys["run"].get("ladder")
    return (f'<p>Placed cells of {which} (harden ladder run <code>{esc(lad or "?")}</code>, netlist '
            f'<code>{phys["run"]["netlist_sha256"][:12]}</code>, built from <code>project.v</code> '
            f'<code>{phys["run"]["project_v_sha256"][:12]}</code>): utilisation '
            f'{m["design__instance__utilization"] * 100:.1f}%, setup {m["timing__setup__ws"]:+.2f} ns, '
            f'{m["design__max_slew_violation__count"]:,} slew warnings, DRC {m["magic__drc_error__count"]}, '
            f'LVS {m["design__lvs_error__count"]}. This is a different run from the one the status above quotes '
            f'unless the two names match.</p>' + (f'<p class="callout">{esc(phys["run"]["note"])}</p>' if phys["run"].get("note") else ""))


# ---------------------------------------------------------------------------
# the die view: the real routed layout, lit by a gate-level recording
# ---------------------------------------------------------------------------
MODNAME = {"u_mom": "Scheduler top: select and dispatch", "u_mom.g_shared": "Cost walker",
           "u_mom.g_shared.u_ce": "Cost engine", "u_mom.u_cal": "Calibration", "u_mom.u_feat": "Features",
           "u_mom.u_sb": "Scoreboard", "u_regs": "Register map", "u_rst_sync": "Reset synchroniser",
           "u_spi": "SPI interface"}
DISPATCH = ("u_mom", "u_mom.g_shared", "u_mom.g_shared.u_ce", "u_mom.u_cal", "u_mom.u_feat", "u_mom.u_sb")
LAYER_WORDS = {"met1": "metal 1", "met2": "metal 2", "met3": "metal 3", "met4": "metal 4"}


def die_arrays(meta, blob, names):
    import gzip, struct
    raw = gzip.decompress(blob)
    out = {}
    for n in names:
        e = meta["bin"]["toc"][n]
        v = list(struct.unpack_from(f"<{e['count']}{e['type']}", raw, e["offset"]))
        if e.get("delta"):
            mod = 1 << (8 * struct.calcsize(e["type"]))
            for i in range(1, len(v)):
                v[i] = (v[i] + v[i - 1]) % mod
        out[n] = v
    return out


def die_facts(die, traces):
    """Every number the die view's words quote, read from die.json, die-gl.json
    and the recorded RTL trace of the same test."""
    d, g = die.get("die"), die.get("die-gl")
    if not d:
        return None
    a = die_arrays(d, die["die.bin"], ["cell_class", "cell_module"])
    fill = sum(1 for k in a["cell_class"] if d["classes"][k] == "fill")
    per_mod = {}
    for m in a["cell_module"]:
        if m & 127:
            name = d["modules"][(m & 127) - 1]
            per_mod.setdefault(name, [0, 0])[1 if m & 128 else 0] += 1
    f = {"w": d["die_um"][2] - d["die_um"][0], "h": d["die_um"][3] - d["die_um"][1], "cells": d["counts"]["cells"],
         "fill": fill, "nets": d["counts"]["nets"], "wires": {k: d["counts"].get(k, 0) for k in LAYER_WORDS},
         "vias": sum(d["counts"].get(v["cut"], 0) for v in d["vias"]), "mods": per_mod,
         "macros": len(d["macros"]), "tpl": d["gds"]["template_rects"]}
    if g:
        e = die_arrays(g, die["die-gl.bin"], ["ev_net"])
        f["switched"] = len(set(e["ev_net"]))
        f["changes"] = g["events"]
        f["c0"], f["c1"] = g["cycles"]
        cx = traces.get(g["trace"])
        if cx:
            win = [x for x in cx["events"] if f["c0"] <= x["c"] <= f["c1"]]
            f["go"] = next((x["c"] for x in win if x["k"] == "go"), f["c0"])
            sel = next((x for x in win if x["k"] == "select"), None)
            f["sel"] = sel
            f["tag"] = next((x for x in win if x["k"] == "tag"), None)
            f["lanes"] = [x for x in win if x["k"] == "lane"]
            f["desc"] = next((x for x in win if x["k"] == "desc"), None)
    return f


ENGWORD = {"ENG_CPU": "CPU", "ENG_SIMD": "vector unit", "ENG_TPU": "systolic array", "ENG_NTT": "butterflies",
           "ENG_CRYPTO": "crypto slot"}


def story_html(f, tile_ver, tiles):
    """The five steps of the opening story, with the numbers from die_facts."""
    if not f:
        return ('<section class="step" data-step="0"><div class="stepcard"><p class="callout warn"><b>Blocked by missing '
                'evidence.</b> No routed layout has been extracted. Run <code>make atlas-die RUN=…</code>.</p></div></section>')
    mods = f["mods"]
    n = lambda k: sum(mods.get(k, [0, 0]))
    w = f["wires"]
    disp = sum(n(k) for k in DISPATCH)
    sel = f.get("sel")
    win = next((r for r in sel["rows"] if r["chosen"]), None) if sel else None
    rej = [ENGWORD.get(r["name"], r["name"]) for r in sel["rows"] if r["why"] == "cannot do this operation or data type"] if sel else []
    d = f.get("desc")
    job = f'{d["m"]}×{d["n"]}×{d["kk"]} {d["dtype"].replace("DT_", "")} {d["op"].replace("OPC_", "")}' if d else "a job"
    lane_rows = "".join(
        f'<tr data-c="{x["c"]}"><td>{esc(ENGWORD.get(x["name"], x["name"]))}</td>'
        f'<td class="num">{"refused" if not x["capable"] else format(x["cost"], ",")}</td></tr>' for x in f.get("lanes", []))
    steps = [
        ("The whole tile, as hardened",
         f'<p>{f["w"]:.1f} × {f["h"]:.1f} µm of layout in the SkyWater 130 nm process, {esc(tiles)} Tiny Tapeout tiles: '
         f'{f["cells"]:,} placed cells, {f["fill"]:,} of them filler, decoupling and tap cells that only complete the rows, '
         f'and {f["nets"]:,} nets routed as {w["met1"]:,} metal-1, {w["met2"]:,} metal-2, {w["met3"]:,} metal-3 and '
         f'{w["met4"]:,} metal-4 rectangles. Every one is drawn from the {esc(tile_ver)} harden\'s own layout file.</p>'
         f'<p class="small">A wire glows while its net is high in a recorded simulation of this very netlist.</p>'),
        ("The dispatch unit is everywhere at once",
         f'<p>A flattened layout has no module boxes, so here are the dispatch unit\'s {disp:,} cells, coloured by the RTL '
         f'block each one belongs to: the cost engine ({n("u_mom.g_shared.u_ce") + n("u_mom.g_shared"):,} with its walker), '
         f'calibration ({n("u_mom.u_cal"):,}), the scoreboard ({n("u_mom.u_sb"):,}) and the select and dispatch logic '
         f'({n("u_mom"):,}). The placer mixed them with the register map and the SPI interface to keep wires short.</p>'
         f'<p class="small">A cell belongs to a block when its output net keeps that block\'s name, or when it drives only '
         f'that block\'s registers (inferred).</p>'),
        ("One decision, cycle by cycle",
         f'<p>Scroll to step through cycles {f.get("go", 0):,} to {sel["c"] if sel else 0:,} of the tile\'s test '
         f'<code>test_roofline_crossover</code>, run on the hardened netlist. GO arrives, the cost engine sweeps the five '
         f'engine rows two cycles each, and the select picks the cheapest one allowed to run {esc(job)}'
         f'{": " + esc(ENGWORD.get(win["name"], win["name"])) + ", by a margin of " + str(sel["margin"]) if win else ""}.</p>'
         f'<table class="mini" aria-label="Engine costs as the sweep writes them"><tbody>{lane_rows}</tbody></table>'
         f'<p class="small" id="story-cycle" aria-live="off">Cycle {f.get("go", 0):,}</p>'),
        ("Down to the cells",
         f'<p>Closer in, every cell is drawn from the process design kit\'s own layout of its type ({f["macros"]} types, '
         f'{f["tpl"]:,} rectangles): green diffusion, red polysilicon gates, violet local interconnect and blue metal 1. '
         f'<span id="story-cell">This is one of the cost engine\'s registers.</span></p>'),
        ("The mask, pulled apart",
         f'<p>Lift the four metal layers off the cells and the routing shows its order: {w["met1"]:,} metal-1, '
         f'{w["met2"]:,} metal-2, {w["met3"]:,} metal-3 and {w["met4"]:,} metal-4 rectangles, joined by '
         f'{f["vias"]:,} vias. The glowing wires on every layer are the nets that are high at the select.</p>'
         '<p class="small">Keep scrolling to turn the stack. In the explorer, the 3D switch does the same, and you can '
         'drag to turn it.</p>'),
        (f'{f.get("switched", 0):,} nets switched to make one decision',
         f'<p>That is {f.get("switched", 0) / f["nets"] * 100:.0f}% of the tile\'s nets, changing value '
         f'{f.get("changes", 0):,} times in {f.get("c1", 0) - f.get("c0", 0) + 1} cycles, for one {esc(job)} sent to the '
         f'{esc(ENGWORD.get(win["name"], win["name"])) if win else "chosen engine"}'
         f'{", with the " + " and the ".join(esc(x) for x in rej) + " refused before any cost was compared" if rej else ""}.</p>'
         '<p class="actions"><a class="btn" href="#layout">Explore the layout</a>'
         f'<a class="textlink" href="#demos/crossover/{sel["c"] if sel else 0}">Replay the decision</a></p>'),
    ]
    return "".join(
        f'<section class="step" data-step="{i}" aria-labelledby="st-{i}"><div class="stepcard">'
        f'<p class="stepn" aria-hidden="true">{i + 1}<span>/{len(steps)}</span></p><h2 id="st-{i}">{t}</h2>{body}</div></section>'
        for i, (t, body) in enumerate(steps))


def die_text(f, die):
    """The die view as text, for anyone not looking at the drawing."""
    if not f:
        return ""
    g = die.get("die-gl")
    rows = "".join(f"<tr><td>{esc(LAYER_WORDS[k])}</td><td class='num'>{v:,}</td></tr>" for k, v in f["wires"].items())
    mods = "".join(f"<tr><td>{esc(MODNAME.get(k, k))} <code>{esc(k)}</code></td><td class='num'>{a:,}</td><td class='num'>{b:,}</td></tr>"
                   for k, (a, b) in sorted(f["mods"].items()))
    prov = (f"<p class='small'>Gate-Level Trace: {esc(g['test'])}, {esc(g['result'])}, on netlist "
            f"<code>{g['netlist_sha256'][:12]}</code>; cycles {g['cycles'][0]:,} to {g['cycles'][1]:,}; every net sampled "
            f"just before the next rising clock edge; {esc(g['pins_match_rtl'])}. <code>{esc(g['command'])}</code></p>" if g else "")
    return (f"<details class='textalt'><summary>The layout as text</summary><div class='grid2'><div><h4>Wires by layer</h4>"
            f"<div class='tablewrap'><table><thead><tr><th>Layer</th><th class='num'>Rectangles</th></tr></thead><tbody>{rows}"
            f"<tr><td>vias, all levels</td><td class='num'>{f['vias']:,}</td></tr></tbody></table></div></div>"
            f"<div><h4>Cells by RTL block</h4><div class='tablewrap'><table><thead><tr><th>Block</th><th class='num'>Named</th>"
            f"<th class='num'>Inferred</th></tr></thead><tbody>{mods}</tbody></table></div></div></div>{prov}</details>")


# ---------------------------------------------------------------------------
# the FPGA memory image in action: its serial-port simulation, as phases
# ---------------------------------------------------------------------------
BANK = {0: "A", 1: "B", 2: "C"}


def fpga_phases(fp, regs):
    """Group the recorded serial bytes into host frames and the board's
    replies, and interleave the dispatch and completion: each phase is one
    thing a person at the board would see happen. Words only, from bytes."""
    if not fp:
        return []
    ev = fp["events"]
    rname = {r["addr"]: r["name"] for r in regs["registers"]}
    frames, cur, last = [], None, -10 ** 9
    for e in ev:
        if e["k"] == "in":
            if e["c"] - last > 60:
                cur = {"c0": e["c"], "c1": e["c"], "in": [], "out": []}
                frames.append(cur)
            cur["in"].append(e["b"]); cur["c1"] = e["c"]; last = e["c"]
        elif e["k"] == "out" and cur is not None:
            cur["out"].append(e["b"]); cur["c1"] = e["c"]
    ph = []
    for f in frames:
        b = f["in"]
        if b[0] == 0xA5 and len(b) > 2:
            spi = b[2]
            rd, addr = spi >> 7, spi & 0x7F
            nm = rname.get(addr, f"0x{addr:02x}")
            if rd:
                txt = f"The host reads {nm} through the bridge's register frame"
                data = f["out"][3:]
                if nm == "ID" and data:
                    txt += f": the board answers \"{''.join(chr(x) for x in data if 32 <= x < 127)}\""
                blocks = ["host", "uart", "bridge", "regs"]
            else:
                txt = f"The host writes {nm} ({len(b) - 3} bytes) through the bridge's register frame"
                if nm == "WD":
                    txt = "The host writes the 16-byte work descriptor, which names the operand banks"
                if nm == "ACTION":
                    txt = "The host writes GO: the scheduler costs every engine for the staged descriptor"
                blocks = ["host", "uart", "bridge", "regs", "sched"]
            kind = "reg"
        elif b[0] == 0x4D:
            bank = BANK.get(b[1], str(b[1]))
            txt = f"'M': the host writes one word into scratchpad bank {bank}, acknowledged with B2"
            blocks, kind = ["host", "uart", "bridge", f"bank{bank}"], "mem"
        elif b[0] == 0x52:
            txt = "'R': the host reads one result word back from bank C"
            blocks, kind = ["host", "uart", "bridge", "bankC"], "read"
        else:
            txt, blocks, kind = f"{len(b)} bytes to the bridge", ["host", "uart", "bridge"], "other"
        ph.append({"c0": f["c0"], "c1": f["c1"], "kind": kind, "text": txt, "blocks": blocks,
                   "in": b, "out": f["out"]})
    eng = fp["engines"]
    for e in ev:
        if e["k"] == "disp":
            ph.append({"c0": e["c"], "c1": e["c"] + 1, "kind": "disp", "blocks": ["sched", "xbar", f"eng{e['eng']}"],
                       "text": f"The scheduler dispatches the job to engine {e['eng']}, the {eng[str(e['eng'])]}, with tag {e['tag']}"})
        if e["k"] == "comp":
            d = next((x for x in ev if x["k"] == "disp" and x["tag"] == e["tag"] and x["c"] <= e["c"]), None)
            n = e["c"] - d["c"] if d else None
            ph.append({"c0": e["c"], "c1": e["c"] + 1, "kind": "comp", "blocks": ["eng2", "bankA", "bankB", "bankC", "xbar", "sched"],
                       "text": f"The array streams both banks through itself, writes the results to bank C and reports tag {e['tag']} done"
                               + (f", {n} cycles after the dispatch" if n else "")})
    ph.sort(key=lambda p: p["c0"])
    # collapse runs of identical reads into one phase with a count
    out = []
    for p in ph:
        if out and p["kind"] == "read" and out[-1]["kind"] == "read":
            q = out[-1]; q["n"] = q.get("n", 1) + 1; q["c1"] = p["c1"]; q["out"] += p["out"]; q["in"] += p["in"]
            q["text"] = f"'R' {q['n']} times: the host reads every result back from bank C"
            continue
        out.append(p)
    return out


def fpga_text(fp, phases):
    if not fp:
        return ""
    lis = "".join(f"<li>cycle {p['c0']:,}: {esc(p['text'])}.</li>" for p in phases)
    return f"<details class='textalt'><summary>This run as text</summary><ol>{lis}</ol></details>"



def big_numbers(f, fp, metrics, timing):
    """One number per screen, each on a full-bleed block of a role colour,
    every one read from the data files: the layout, the gate-level run, the
    FPGA image's simulation."""
    if not f:
        return "", ""
    disp = next((e for e in (fp or {}).get("events", []) if e["k"] == "disp"), None)
    comp = next((e for e in (fp or {}).get("events", []) if e["k"] == "comp"), None)
    items = [
        ("amber", "Placed cells", f"{f['cells']:,}",
         f"standard cells on {f['w']:.1f} × {f['h']:.1f} µm of the hardened tile, every one drawn above from the layout file."),
        ("blue", "Nets", f"{f['nets']:,}",
         "wires between them, routed on four metal layers, each one you can find by name in the explorer."),
        ("red", "Switched", f"{f.get('switched', 0):,}",
         f"nets changed value to make one decision, {f.get('changes', 0):,} times in {f.get('c1', 0) - f.get('c0', 0) + 1} cycles of the gate-level recording."),
    ]
    if disp and comp:
        items.append(("green", "Cycles on the array", f"{comp['c'] - disp['c']}",
                      "from dispatch to done for the FPGA memory image's job, in its own simulation (not a board run)."))
    secs = "".join(
        f'<section class="bignum bn-{c}" aria-label="{esc(k)}"><div class="bn-in wrap">'
        f'<p class="bn-k">{esc(k)}</p>'
        f'<p class="bn-n"><span class="o" aria-hidden="true">{n}</span><span class="f">{n}</span></p>'
        f'<p class="bn-t">{esc(tx)}</p></div></section>' for c, k, n, tx in items)
    t_last = timing[-1]
    gl = next((v["result"] for v in metrics["verification"] if v.get("target") == "tile-gl"), None)
    facts = [f"{f['cells']:,} cells", f"{f['nets']:,} nets", f"{f.get('switched', 0):,} switched in one decision",
             f"setup {min(c[1] for c in t_last['corners']):+.2f} ns at {len(t_last['corners'])} corners",
             f"DRC {t_last['drc']} · LVS {t_last['lvs']}"]
    if gl:
        facts.append(f"{gl} gate-level tests")
    if fp and fp.get("pnr"):
        facts.append(f"{fp['pnr']['luts']:,} LUTs on ECP5")
    one = "".join(f"<span>{esc(x)}</span><i></i>" for x in facts)
    band = f'<div class="marquee" aria-hidden="true"><div class="mq">{one}{one}</div></div>'
    return secs, band


def flow_html(flow):
    if not flow:
        return ('<p class="callout warn"><b>Blocked by missing evidence.</b> No harden run has been summarised. '
                'Run <code>make atlas-flow</code>.</p>')
    rows = "".join(f"<li class='fstep{'' if s['detail'] else ' quiet'}'><span class='fk'>{s['n']}</span><span class='fn'>{esc(s['name'])}</span><span class='fd'>{esc(s['detail'])}</span></li>"
                   for s in flow["steps"])
    return (f"<p><span class='kind'>Recorded Tool Output</span></p><p>Every step of LibreLane run <code>{esc(flow['run'])}</code> ({esc(flow['what'])}), in order, "
            f"with what its own log or report says.</p><ol class='flow'>{rows}</ol>")


# ---------------------------------------------------------------------------
CSS = r"""
/* Mask Room. The light theme is the safelit room, the dark theme the mask;
   the die view is always the mask. One family in two widths: condensed for
   display, normal for reading, its mono only for code, signal names and
   bytes. Six text steps. Surfaces are separated by tone. Motion: a spring on
   the die camera, an afterglow on wires that fall, an exposure wipe when a
   step arrives, press feedback on controls; nothing moves on its own except
   a recording you asked to play, and reduced motion keeps only colour. */
:root{color-scheme:light dark;--sans:"Ubuntu Sans",ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
--mono:"Ubuntu Sans Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; /* taste-skill-ignore: code, signal names and bytes only */--r:14px;--r-s:8px;--bar:58px;
--fs-1:13px;--fs-2:15px;--fs-3:17px;--fs-4:22px;--fs-5:clamp(28px,3.4vw,40px);--fs-6:clamp(64px,11vw,168px);
--ease-out:cubic-bezier(.23,1,.32,1);--ease-in-out:cubic-bezier(.77,0,.175,1);
--sp-1:4px;--sp-2:8px;--sp-3:12px;--sp-4:20px;--sp-5:32px;--sp-6:56px;--sp-7:96px;
--die-sub:#07080b;--mark:rgba(236,233,224,.38)}
*,*::before,*::after{box-sizing:border-box}
html{scroll-padding-top:calc(var(--bar) + 12px);accent-color:var(--control);scrollbar-color:var(--line) var(--bg)}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 var(--sans);caret-color:var(--control);-webkit-font-smoothing:antialiased}
::selection{background:var(--control-t);color:var(--ink)}
a{color:var(--signal);text-underline-offset:.18em;text-decoration-thickness:1px}
@media (hover:hover) and (pointer:fine){a:hover{text-decoration-thickness:2px}}
code,kbd{font-family:var(--mono);font-size:.88em;background:var(--surface);border-radius:5px;padding:.08em .32em}
kbd{background:var(--raised)}
pre code{background:none;padding:0}
pre{background:var(--surface);border-radius:var(--r-s);padding:var(--sp-3) var(--sp-4);overflow-x:auto;font-size:var(--fs-1)}
.num,td.num,th.num{font-variant-numeric:tabular-nums;text-align:right;white-space:nowrap}
.skip{position:absolute;left:-9999px;top:8px;z-index:30;background:var(--raised);color:var(--ink);padding:8px 12px;border-radius:8px}
.skip:focus{left:12px}
:focus-visible{outline:2px solid var(--control);outline-offset:3px;border-radius:6px}
.wrap{max-width:1240px;margin-left:auto;margin-right:auto;padding-left:24px;padding-right:24px}
/* the bar: opaque, one tone up from the page */
.top{position:sticky;top:0;z-index:20;background:var(--surface)}
.top .wrap{display:flex;align-items:center;gap:var(--sp-3) var(--sp-4);min-height:var(--bar);flex-wrap:wrap}
.brand{font-weight:700;font-size:var(--fs-2);text-decoration:none;color:var(--ink);display:flex;gap:10px;align-items:center;font-stretch:87.5%}
.brand svg{width:22px;height:22px;color:var(--control)}
.brand small{font-weight:400;color:var(--ink2);font-size:var(--fs-1);font-stretch:100%}
nav.tabs{display:flex;gap:2px;flex-wrap:wrap;flex:1}
nav.tabs a{padding:7px 10px;border-radius:var(--r-s);color:var(--ink2);text-decoration:none;font-size:14.5px;white-space:nowrap;
 transition:background-color 150ms ease,color 150ms ease}
@media (hover:hover) and (pointer:fine){nav.tabs a:hover{background:var(--bg);color:var(--ink)}}
nav.tabs a[aria-current="page"]{background:var(--bg);color:var(--ink);font-weight:600}
.theme{display:flex;gap:2px;background:var(--bg);border-radius:var(--r-s);padding:3px}
.theme button{font:var(--fs-1) var(--sans);background:none;border:0;color:var(--ink2);padding:5px 10px;border-radius:6px;cursor:pointer;min-height:34px}
.theme button[aria-pressed="true"]{background:var(--raised);color:var(--ink);font-weight:600}
main{padding:0 0 var(--sp-7)}
section.panel{display:block}
section.panel.wrap{padding-top:var(--sp-5)}
.js section.panel[hidden]{display:none}
.js section.panel.enter{animation:enter 240ms var(--ease-out)}
@keyframes enter{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
h1,h2,h3{font-stretch:75%;font-weight:700;text-wrap:balance}
h1{font-size:var(--fs-6);line-height:.86;letter-spacing:-.02em;margin:0 0 var(--sp-4)}
h2{font-size:var(--fs-5);line-height:1.05;letter-spacing:-.01em;margin:var(--sp-6) 0 var(--sp-3)}
section.panel>h2:first-child{margin-top:var(--sp-4)}
h3{font-size:var(--fs-4);line-height:1.2;margin:var(--sp-5) 0 var(--sp-2)}
h4{margin:var(--sp-4) 0 var(--sp-2);font-size:var(--fs-3);line-height:1.3}
h5{margin:var(--sp-4) 0 var(--sp-1);font-size:var(--fs-2);color:var(--ink2)}
p{max-width:70ch;margin:0 0 var(--sp-3)}
.lede{font-size:var(--fs-4);line-height:1.4;color:var(--ink);max-width:30ch;margin-bottom:var(--sp-4)}
.muted{color:var(--ink2)}
.small{font-size:var(--fs-1);color:var(--ink2)}
.callout{background:var(--control-t);padding:var(--sp-3) var(--sp-4);border-radius:var(--r);max-width:72ch}
.callout.warn{background:var(--danger-t)}
.actions{display:flex;gap:var(--sp-3) var(--sp-4);flex-wrap:wrap;align-items:center;margin:var(--sp-4) 0 0}
.btn{display:inline-flex;align-items:center;gap:8px;min-height:44px;padding:0 20px;border-radius:999px;background:var(--control);color:var(--on-accent);
 text-decoration:none;font-weight:700;font-size:var(--fs-2);transition:transform 160ms var(--ease-out),filter 150ms ease}
@media (hover:hover) and (pointer:fine){.btn:hover{filter:brightness(1.08)}}
.btn:active,.controls button:active,.tourstep:active,.theme button:active,.zoombtns button:active,.excontrols button:active{transform:scale(.97)}
.textlink{font-weight:600;font-size:var(--fs-2);color:var(--ink);text-decoration:underline;text-decoration-color:var(--line);text-underline-offset:.3em}
@media (hover:hover) and (pointer:fine){.textlink:hover{text-decoration-color:var(--ink)}}

/* ---- the opening story: a sticky die, steps scrolling over it ---- */
.mask{accent-color:var(--control);color:var(--ink);caret-color:var(--control)}
.band{background:var(--bg);padding:var(--sp-2) 0 var(--sp-6);margin-top:var(--sp-6)}
.band>.wrap>h2:first-child{margin-top:var(--sp-5)}
header.top.mask,footer.mask{background:var(--surface)}
.story{position:relative;background:var(--die-sub);color:var(--ink)}
.diestage{position:sticky;top:var(--bar);height:calc(100svh - var(--bar));overflow:hidden;background:var(--die-sub)}
.diestage canvas{position:absolute;inset:0;width:100%;height:100%;display:block;touch-action:pan-y}
.diestage .still{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;opacity:.55}
.js-die .diestage .still{display:none}
/* reticle alignment marks at the four corners: the frame is a mask */
.mk{position:absolute;width:17px;height:17px;pointer-events:none}
.mk::before,.mk::after{content:"";position:absolute;background:var(--mark)}
.mk::before{left:8px;top:0;width:1px;height:17px}.mk::after{left:0;top:8px;width:17px;height:1px} /* taste-skill-ignore: a drawn alignment mark, not a divider */
.mk.tl{left:14px;top:14px}.mk.tr{right:14px;top:14px}.mk.bl{left:14px;bottom:14px}.mk.br{right:14px;bottom:14px}
.intro{position:relative;margin-top:calc(-100svh + var(--bar));min-height:calc(100svh - var(--bar));display:flex;flex-direction:column;
 justify-content:flex-end;padding-bottom:var(--sp-6);pointer-events:none}
.intro>*{pointer-events:auto}
.intro h1{color:var(--ink)}
.scrollcue{display:flex;align-items:center;gap:10px;font-size:var(--fs-1);color:var(--ink2)}
.scrollcue span{width:1px;height:28px;background:var(--ink2);transform-origin:top;animation:cue 2.4s var(--ease-in-out) infinite}
@keyframes cue{0%{transform:scaleY(0)}45%{transform:scaleY(1)}100%{transform:scaleY(1);opacity:0}}
.steps{position:relative}
.step{min-height:100svh;display:flex;align-items:center;justify-content:flex-end;padding:var(--sp-6) max(24px,calc((100vw - 1240px) / 2 + 24px));pointer-events:none}
.stepcard{pointer-events:auto;width:min(420px,100%);background:color-mix(in srgb,var(--surface) 94%,transparent);border-radius:var(--r);padding:var(--sp-4) var(--sp-4) var(--sp-3)}
.stepcard h2{margin:0 0 var(--sp-3);font-size:clamp(26px,2.6vw,34px)}
.stepcard p{font-size:var(--fs-2)}
.stepn{font:700 var(--fs-4)/1 var(--sans);font-stretch:75%;color:var(--control);margin:0 0 var(--sp-2);font-variant-numeric:tabular-nums}
.stepn span{color:var(--dim);font-weight:400}
.js .step.armed .stepcard{clip-path:inset(0 0 100% 0)}
.js .step.armed.lit .stepcard{clip-path:inset(0 0 0 0);transition:clip-path 420ms var(--ease-out)}
table.mini{width:auto;min-width:240px;margin:0 0 var(--sp-3);font-size:var(--fs-1)}
table.mini td{padding:3px 12px 3px 0;border-bottom:1px solid var(--line2);color:var(--dim);transition:color 160ms ease}
table.mini tr.on td{color:var(--ink)}
table.mini tr.win td{color:var(--control);font-weight:700}
.scalebar{position:absolute;left:28px;bottom:26px;display:flex;align-items:center;gap:10px;font:var(--fs-1) var(--mono);color:var(--ink2);pointer-events:none;background:var(--surface);padding:5px 10px;border-radius:6px}
.scalebar span{display:block;height:7px;border:1px solid var(--ink2);border-top:0} /* taste-skill-ignore: the scale bar itself */
.dielabels{position:absolute;inset:0;pointer-events:none}
.dielabels i{position:absolute;font:600 var(--fs-1)/1.2 var(--sans);font-style:normal;color:var(--ink);background:var(--surface);padding:3px 8px;border-radius:999px;
 transform:translate(-50%,-140%);white-space:nowrap;display:flex;gap:6px;align-items:center;transition:opacity 200ms ease}
.dielabels i::before{content:"";width:8px;height:8px;border-radius:50%;background:var(--c)}
.dielabels i::after{content:"";position:absolute;left:50%;top:100%;width:1px;height:8px;background:var(--ink2)}
.lane-hud{position:absolute;left:44px;top:26px;font:var(--fs-1) var(--mono);color:var(--ink2);pointer-events:none;display:flex;gap:14px;background:var(--surface);padding:4px 10px;border-radius:6px}
.lane-hud:empty{display:none}
.cellmark{position:absolute;pointer-events:none;opacity:0;transition:opacity 220ms ease}
.cellmark i{position:absolute;width:12px;height:12px;border:0 solid var(--control)}
.cellmark i:nth-child(1){left:0;top:0;border-width:2px 0 0 2px}.cellmark i:nth-child(2){right:0;top:0;border-width:2px 2px 0 0}
.cellmark i:nth-child(3){left:0;bottom:0;border-width:0 0 2px 2px}.cellmark i:nth-child(4){right:0;bottom:0;border-width:0 2px 2px 0}
.cellmark.on{opacity:1}
.cellmark::after{content:attr(data-name);position:absolute;left:0;top:calc(100% + 8px);font:600 var(--fs-1) var(--mono);color:var(--ink);background:var(--surface);padding:3px 8px;border-radius:6px;white-space:nowrap}
.lane-hud b{color:var(--control);font-weight:600}
.diestate{position:absolute;inset:0;display:grid;place-items:center;pointer-events:none;text-align:center;padding:24px}
.diestate:empty{display:none}
.story .diestate{place-items:start end;padding:72px 32px}
.story .diestage .still{opacity:.32}
.scalebar,.lane-hud{display:none}.js-die .scalebar,.js-die .lane-hud{display:flex}
.js-die .lane-hud:empty{display:none}
.diestate div{background:var(--surface);color:var(--ink);border-radius:var(--r);padding:var(--sp-3) var(--sp-4);max-width:46ch;font-size:var(--fs-2)}
.diestate .bar{height:2px;background:var(--line);border-radius:2px;margin-top:10px;overflow:hidden}
.diestate .bar i{display:block;height:100%;width:40%;background:var(--control);animation:develop 1.1s var(--ease-in-out) infinite}
@keyframes develop{from{transform:translateX(-100%)}to{transform:translateX(250%)}}

/* ---- the explorer ---- */
.explorer{display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:0;border-radius:var(--r);overflow:hidden;background:var(--surface);margin:var(--sp-4) 0 var(--sp-2)}
.explorer .diestage{position:relative;top:auto;height:auto;min-height:600px;border-radius:0}
.explorer .diestage canvas{touch-action:none;cursor:grab}
.explorer .diestage canvas:active{cursor:grabbing}
.explorer .diestage canvas:focus-visible{outline:2px solid var(--control);outline-offset:-4px}
.coords{position:absolute;right:28px;bottom:26px;font:var(--fs-1) var(--mono);color:var(--ink2);pointer-events:none;font-variant-numeric:tabular-nums}
.zoombtns{position:absolute;right:20px;top:20px;display:flex;flex-direction:column;gap:6px}
.zoombtns button,.excontrols button{display:grid;place-items:center;min-width:44px;min-height:44px;border:0;border-radius:var(--r-s);background:var(--raised);color:var(--ink);
 font:600 var(--fs-3) var(--sans);cursor:pointer;transition:transform 160ms var(--ease-out),background-color 150ms ease}
.zoombtns button#ex-fit{font-size:var(--fs-1)}
@media (hover:hover) and (pointer:fine){.zoombtns button:hover,.excontrols button:hover{background:var(--line2)}}
.excontrols button svg{width:18px;height:18px}
.excontrols button[aria-pressed="true"]{background:var(--control);color:var(--on-accent)}
.exside{padding:var(--sp-4);display:flex;flex-direction:column;gap:var(--sp-3);font-size:var(--fs-2);color:var(--ink);background:var(--surface);overflow:auto}
.excontrols{display:flex;gap:var(--sp-2);align-items:center}
.excontrols input{flex:1;min-width:80px;border:0;background:none;padding:0;min-height:44px}
.excap{margin:0;color:var(--ink2);min-height:4.8em;font-size:var(--fs-1)}
.find{font-weight:600;font-size:var(--fs-1);color:var(--ink2)}
.exside input[list]{font:var(--fs-1) var(--mono);color:var(--ink);background:var(--raised);border:0;border-radius:var(--r-s);padding:9px 10px;min-height:42px;width:100%}
.netinfo{background:var(--raised);border-radius:var(--r-s);padding:var(--sp-3);font-size:var(--fs-1);min-height:5.5em}
.netinfo p{margin:0 0 4px}.netinfo code{background:none;padding:0;overflow-wrap:anywhere}
fieldset.layers{border:0;margin:0;padding:0}
fieldset.layers legend{font-weight:600;font-size:var(--fs-1);color:var(--ink2);padding:0;margin-bottom:6px}
#ex-layers{display:flex;flex-wrap:wrap;gap:6px}
#ex-layers label{display:inline-flex;align-items:center;gap:6px;font-size:var(--fs-1);background:var(--raised);border-radius:999px;padding:5px 10px 5px 8px;cursor:pointer;min-height:32px}
#ex-layers label i{width:10px;height:10px;border-radius:2px;background:var(--c)}
#ex-layers input{margin:0}
.focus{display:flex;gap:8px;align-items:center;font-size:var(--fs-2);cursor:pointer;min-height:32px}
ul.modlegend{list-style:none;margin:0;padding:0;font-size:var(--fs-1);display:grid;gap:3px}
ul.modlegend li{display:flex;gap:8px;align-items:center}
ul.modlegend i{width:10px;height:10px;border-radius:50%;background:var(--c);flex:none}
ul.modlegend .num{margin-left:auto;color:var(--ink2)}
.still-fig{margin-top:var(--sp-5);max-width:820px}
.still-fig img{width:100%;height:auto;border-radius:var(--r);display:block}


/* the FPGA image in action: a board drawing, lit by the recorded run */
.fpga{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:var(--sp-4);align-items:start;margin-top:var(--sp-4)}
.fpgastage{background:var(--surface);border-radius:var(--r);padding:var(--sp-3);overflow-x:auto}
.fpgastage svg{display:block;width:100%;min-width:720px;height:auto}
.fpgaside{background:var(--surface);border-radius:var(--r);padding:var(--sp-4)}
.fpgaside .controls{margin-top:0}.fpgaside .controls input{min-width:80px}
dl.pnr{display:grid;grid-template-columns:1fr auto;gap:4px 14px;margin:0;font-size:var(--fs-2)}dl.pnr dt{color:var(--ink2)}dl.pnr dd{margin:0}
.fb-board{fill:var(--memory-t);stroke:var(--memory);stroke-opacity:.45;stroke-width:1.5}
.fb-fpga{fill:var(--raised);stroke:var(--line);stroke-width:1.5}.fb-pin{fill:var(--dim)}.fb-part{fill:var(--raised);stroke:var(--line)}
.fb-b rect{fill:var(--rt);stroke:var(--rc);stroke-width:1.4;transition:fill 200ms ease,stroke-width 200ms ease}
.fb-b.model rect{stroke-dasharray:4 3}
.fb-b.on rect{fill:var(--rc);stroke-width:2.2}.fb-b.on .fb-t,.fb-b.on .fb-s{fill:var(--on-accent)}
.fb-b.host.on rect{fill:var(--rt);stroke-width:3}.fb-b.host.on .fb-t,.fb-b.host.on .fb-s{fill:var(--ink)}
.fb-b.busy rect{animation:fbpulse 700ms var(--ease-in-out) infinite alternate}
@keyframes fbpulse{to{fill-opacity:.55}}
.fb-w{fill:none;stroke:var(--line);stroke-width:2}
.fb-w.on{stroke:var(--rc);stroke-width:3;stroke-dasharray:7 5;animation:fbflow 600ms linear infinite}
@keyframes fbflow{to{stroke-dashoffset:-12}}
.fb-t{font:600 13px var(--sans);fill:var(--ink)}.fb-s{font:11.5px var(--sans);fill:var(--ink2)}.fb-cap{font:600 13px var(--sans);fill:var(--ink2)}
.fb-m{font:12.5px var(--mono);fill:var(--ink)}.fb-m.in{fill:var(--signal)}.fb-m.out{fill:var(--memory)}
.fb-bead{fill:var(--rc)}.fb-bx{font:700 8.5px var(--mono);fill:var(--on-accent)}
@media (max-width:980px){.fpga{grid-template-columns:1fr}}
@media (prefers-reduced-motion:reduce){.fb-w.on,.fb-b.busy rect{animation:none}}


/* paper grain in the safelit room; none on the mask */
body{background-image:var(--grain,none)}
.mask,.story,.band{background-image:none}
/* the exploded stack's layer names */
.layerlabels{position:absolute;inset:0;pointer-events:none;opacity:0;transition:opacity 260ms ease}
.layerlabels.on{opacity:1}
.layerlabels i{position:absolute;transform:translateY(-50%);font:var(--fs-1)/1.2 var(--mono);font-style:normal;color:var(--ink2);white-space:nowrap;
 background:var(--surface);padding:3px 9px;border-radius:6px}
.layerlabels b{color:var(--ink);font:600 var(--fs-1) var(--sans);margin-right:6px}
/* one number per screen, on a block of colour; the fill is exposed as it scrolls in */
.bignum{position:relative;min-height:88svh;padding:var(--sp-6) 0;display:flex;align-items:center;overflow:hidden;--p:0}
.bn-in{position:relative;width:100%}
.bn-amber{background:#ffc145;color:#16130b}.bn-blue{background:#2346c4;color:#fbfaf6}
.bn-red{background:#a8231b;color:#fbfaf6}.bn-green{background:#11683a;color:#fbfaf6}
.bn-k{font:700 var(--fs-4)/1 var(--sans);font-stretch:75%;margin:0 0 var(--sp-3)}
.bn-n{position:relative;margin:0;font-weight:800;font-stretch:75%;font-size:clamp(120px,24vw,340px);line-height:.82;letter-spacing:-.01em;
 font-variant-numeric:tabular-nums;transform:scale(calc(.94 + var(--p) * .06));transform-origin:left center}
.bn-n .o{color:transparent;-webkit-text-stroke:3px currentColor}
.bn-n .f{position:absolute;left:0;top:0;clip-path:inset(0 calc((1 - var(--p)) * 100%) 0 0)}
.bn-t{font-size:var(--fs-4);line-height:1.35;max-width:34ch;margin:var(--sp-4) 0 0}
/* the fact band */
.marquee{overflow:hidden;background:#16130b;color:#ffc145;padding:14px 0;white-space:nowrap}
.mq{display:inline-flex;align-items:center;gap:28px;animation:mq 46s linear infinite;padding-left:28px}
.mq span{font:700 clamp(20px,2.4vw,32px)/1 var(--sans);font-stretch:75%}
.mq i{width:12px;height:12px;background:#ffc145;transform:rotate(45deg);flex:none}
@keyframes mq{to{transform:translateX(-50%)}}
@media (hover:hover){.marquee:hover .mq{animation-play-state:paused}}
/* the FPGA board answers the pointer with a slight tilt */
.fpgastage{perspective:1400px}.fpgastage svg{transition:transform 240ms var(--ease-out);transform-origin:center}
.zoombtns button#ex-3d{font-size:var(--fs-1)}.zoombtns button[aria-pressed="true"]{background:var(--control);color:var(--on-accent)}
@media (max-width:760px){.bignum{min-height:62svh}}
@media (prefers-reduced-motion:reduce){.mq{animation:none}.bignum{--p:1}.bn-n{transform:none}.fpgastage svg{transition:none}.layerlabels{transition:none}}

/* ---- the rest of the atlas ---- */
.split{display:grid;grid-template-columns:minmax(0,.8fr) minmax(0,1.2fr);gap:var(--sp-5);align-items:center}
.split figure{margin:0;background:var(--surface);border-radius:var(--r);padding:var(--sp-4)}
.split figure svg{display:block;width:100%;height:auto}
.decision .t{font:600 var(--fs-2) var(--sans);fill:var(--ink)}
.decision .s{font:var(--fs-1) var(--sans);fill:var(--ink2)}
.decision .v{font:600 var(--fs-1) var(--sans);fill:var(--ink);font-variant-numeric:tabular-nums}
.decision .bar{fill:var(--control);opacity:.45}.decision .bar.win{opacity:1}
.decision .bar.e0{fill:var(--signal)}.decision .bar.e1{fill:var(--memory)}.decision .bar.e2{fill:var(--compute)}
.decision .no{fill:var(--danger)}
.decision .base{fill:var(--raised)}
.targets{display:grid;gap:var(--sp-4);grid-template-columns:repeat(auto-fit,minmax(min(100%,320px),1fr));margin-top:var(--sp-4);align-items:stretch}
.target{background:var(--surface);border-radius:var(--r);padding:var(--sp-4);border-top:6px solid var(--tc,var(--line))}
.t-tile{--tc:var(--control)}.t-chip{--tc:var(--compute)}.t-fpga{--tc:var(--memory)}
.target h3{margin:0 0 var(--sp-2);display:flex;gap:var(--sp-2);align-items:center}
.target p{color:var(--ink2);font-size:var(--fs-2);margin:0 0 var(--sp-3)}
.target dl{display:grid;grid-template-columns:auto 1fr;gap:6px 14px;margin:0;font-size:var(--fs-2)}
.target dt{color:var(--ink2)}.target dd{margin:0}
.target .dot{width:10px;height:10px;border-radius:2px;flex:none}
.t-tile .dot{background:var(--control)}.t-chip .dot{background:var(--compute)}.t-fpga .dot{background:var(--memory)}
ol.tour li:nth-child(1){--rc:var(--signal);--rt:var(--signal-t)}ol.tour li:nth-child(2){--rc:var(--control);--rt:var(--control-t)}
ol.tour li:nth-child(3){--rc:var(--compute);--rt:var(--compute-t)}ol.tour li:nth-child(4){--rc:var(--memory);--rt:var(--memory-t)}
ol.tour li{display:flex}ol.tour li>.tourstep{flex:1}
ol.tour{list-style:none;padding:0;margin:var(--sp-4) 0 0;display:grid;gap:var(--sp-5) var(--sp-4);
 grid-template-columns:repeat(auto-fit,minmax(min(100%,230px),1fr))}
.tourstep{all:unset;cursor:pointer;display:block;border-radius:var(--r);padding:var(--sp-4);background:var(--rt);
 transition:background-color 150ms ease,transform 160ms var(--ease-out)}
@media (hover:hover) and (pointer:fine){.tourstep:hover{background:var(--raised)}}
.tourstep:focus-visible{outline:2px solid var(--control);outline-offset:2px}
.tourstep .n{display:block;font-size:var(--fs-5);font-weight:700;font-stretch:75%;line-height:1;color:var(--rc);font-variant-numeric:tabular-nums;margin-bottom:var(--sp-2)}
.tourstep .tt{display:block;font-weight:700;font-size:var(--fs-3);margin-bottom:var(--sp-1)}
.tourstep .td{display:block;color:var(--ink2);font-size:var(--fs-2)}
ul.labels{padding-left:1.2em;max-width:80ch;font-size:var(--fs-2)}ul.labels li{margin:4px 0}
.legend{display:flex;flex-wrap:wrap;gap:var(--sp-2) var(--sp-4);font-size:var(--fs-2);margin:var(--sp-3) 0;padding:0;list-style:none}
.legend li{display:flex;align-items:center;gap:8px}
svg.ico{width:14px;height:14px;flex:none;vertical-align:-2px}
.r-signal{--rc:var(--signal);--rt:var(--signal-t)}.r-control{--rc:var(--control);--rt:var(--control-t)}
.r-compute{--rc:var(--compute);--rt:var(--compute-t)}.r-memory{--rc:var(--memory);--rt:var(--memory-t)}
.r-secure{--rc:var(--secure);--rt:var(--secure-t)}
svg.ico{color:var(--rc)}
.toolbar{display:flex;flex-wrap:wrap;gap:var(--sp-3);align-items:center;margin:var(--sp-3) 0}
select,input[type=range]{font:inherit;font-size:var(--fs-2);color:var(--ink);background:var(--raised);border:1px solid var(--line);border-radius:var(--r-s);
 padding:8px 10px;min-height:42px;max-width:100%}
.scroll{overflow-x:auto;background:var(--surface);border-radius:var(--r);padding:var(--sp-3)}
svg.logical{display:block;min-width:640px;width:100%;height:auto}
.node rect{fill:var(--rt);stroke:var(--rc);stroke-width:1.2}
.node:hover rect,.node:focus rect,.node.on rect{stroke-width:2.4}
.node .nl{font:600 13px var(--sans);fill:var(--ink)}
.node .ns{font:11.5px var(--sans);fill:var(--ink2)}
.node .sym{fill:var(--rc)}
.node{cursor:pointer;outline:none}
.edge{fill:none;stroke:var(--line);stroke-width:1.5}
.edge.hot{stroke:var(--rc);stroke-width:2.6}
figcaption{font-size:var(--fs-1);color:var(--ink2);margin-top:var(--sp-2);max-width:80ch}
details.textalt{margin:var(--sp-3) 0}
details summary{cursor:pointer;color:var(--signal);font-size:var(--fs-2);font-weight:600}
.cardfilters{display:flex;flex-wrap:wrap;gap:var(--sp-3);align-items:center}
.cards{display:grid;gap:var(--sp-4);grid-template-columns:repeat(auto-fill,minmax(min(100%,360px),1fr));margin-top:var(--sp-4);align-items:start}
.card{background:var(--surface);border-radius:var(--r);padding:var(--sp-4)}
.card header{display:flex;gap:10px;align-items:center}
.card h3{margin:0;font-size:var(--fs-4)}
.card .role{margin-left:auto;font-size:var(--fs-1);color:var(--ink2)}
.card .job{margin:var(--sp-2) 0 var(--sp-3);font-size:var(--fs-2)}
.card.flash{outline:2px solid var(--rc);outline-offset:2px}
.avail{list-style:none;padding:0;margin:0 0 var(--sp-2);display:flex;flex-wrap:wrap;gap:6px}
.avail li{font-size:var(--fs-1);background:var(--bg);border-radius:999px;padding:2px 10px;color:var(--ink2)}
.avail li.none{background:none;padding-left:0;font-style:italic}
.card dl{margin:var(--sp-2) 0 0}.card dt{font-weight:650;font-size:var(--fs-2);margin-top:var(--sp-3)}.card dd{margin:2px 0 0;font-size:var(--fs-2);color:var(--ink2)}
table{border-collapse:collapse;width:100%;font-size:var(--fs-2);font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--line2);vertical-align:top}
thead th{font-size:var(--fs-1);font-weight:600;color:var(--ink2);border-bottom-color:var(--line)}
tbody tr:last-child td,tbody tr:last-child th{border-bottom:0}
.tablewrap{overflow-x:auto;background:var(--surface);border-radius:var(--r)}
table.io{font-size:var(--fs-1)}
ul.cites{font-size:var(--fs-1);color:var(--ink2)}.warnline{color:var(--control);list-style:none;margin-left:-1em}
.grid2{display:grid;gap:var(--sp-5);grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr))}
.player{background:var(--surface);border-radius:var(--r);padding:var(--sp-4)}
.phead{display:flex;flex-wrap:wrap;gap:var(--sp-3);align-items:center}
.kind{display:inline-flex;align-items:center;gap:8px;font-size:var(--fs-1);font-weight:600;color:var(--ink)}
.kind::before{content:"";width:8px;height:8px;border-radius:2px;background:var(--control)}
.prov{font-size:var(--fs-1);color:var(--ink2);overflow-wrap:anywhere;margin-top:var(--sp-2);max-width:none}
.controls{display:flex;flex-wrap:wrap;gap:var(--sp-2);align-items:center;margin:var(--sp-3) 0}
.controls button{display:inline-grid;place-items:center;font:600 var(--fs-2) var(--sans);min-width:44px;min-height:44px;border:0;background:var(--raised);
 color:var(--ink);border-radius:var(--r-s);cursor:pointer;padding:0 12px;transition:transform 160ms var(--ease-out),background-color 150ms ease}
.controls button svg{width:18px;height:18px}
@media (hover:hover) and (pointer:fine){.controls button:hover{background:var(--bg)}}
.controls button[aria-pressed="true"]{background:var(--control);color:var(--on-accent)}
.controls input[type=range]{flex:1;min-width:160px;border:0;background:none;padding:0}
.clock{font-weight:600;font-size:var(--fs-2);font-variant-numeric:tabular-nums;min-width:12ch;text-align:right}
.excontrols .clock{min-width:7ch;font-size:var(--fs-1)}
.caption{min-height:3.4em;font-size:var(--fs-3);line-height:1.45;padding:var(--sp-3) var(--sp-4);border-radius:var(--r-s);background:var(--raised)}
.stage-svg,.stagesvg{display:block}
svg.stage{display:block;width:100%;height:auto;min-width:640px;position:static}
svg.tpu{display:block;width:100%;max-width:620px;height:auto;margin:0 auto}
.st rect{fill:var(--raised);stroke:var(--line2);stroke-width:1.2;transition:fill 180ms ease,stroke 180ms ease}
.st.on rect{fill:var(--rt);stroke:var(--rc);stroke-width:2.2}
.st text{font:600 12.5px var(--sans);fill:var(--ink);text-anchor:middle}
.st text.sub{font:11.5px var(--sans);fill:var(--ink2)}
.sedge{stroke:var(--line);stroke-width:1.5;fill:none}
.sedge.on{stroke:var(--signal);stroke-width:2.6}
.costs .bar{height:10px;border-radius:999px;background:var(--control);display:inline-block;vertical-align:middle;transition:width 220ms var(--ease-out)}
.costs td.why{color:var(--ink2)}
.costs tr.win td{font-weight:700}
.costs td svg{width:13px;height:13px;vertical-align:-1px;margin-right:6px}
.costs tr.rej td svg{color:var(--danger)}.costs tr.win td svg{color:var(--ok)}
.tags{display:flex;gap:var(--sp-2)}
.tagc{flex:1;border-radius:var(--r-s);padding:8px;text-align:center;font-weight:600;font-size:var(--fs-1);background:var(--raised);
 transition:background-color 180ms ease,color 180ms ease}
.tagc.busy{background:var(--control);color:var(--on-accent)}
.bytes{font:var(--fs-1)/1.6 var(--mono);overflow-wrap:anywhere}
.wave{display:block;width:100%;height:auto}
.wave text{font:11px var(--mono);fill:var(--ink2)}
.wave .w{fill:none;stroke:var(--signal);stroke-width:1.4}
.wave .cur{stroke:var(--control);stroke-width:1.5}
.wave .bus{fill:var(--signal-t);stroke:var(--signal);stroke-width:1}
.chart{display:block;width:100%;height:auto}
.chart text{font:11.5px var(--sans);fill:var(--ink2)}
figure.film{margin:0}figure.film video,figure.film img{width:100%;height:auto;border-radius:var(--r);background:var(--surface);display:block}
svg.pins{display:block;width:100%;height:auto;min-width:620px}
svg.pins .die{fill:var(--raised);stroke:var(--ink);stroke-width:1.4}
svg.pins .dl{font:700 15px var(--mono);fill:var(--ink)}svg.pins .ds{font:12px var(--sans);fill:var(--ink2)}
svg.pins line.used{stroke:var(--signal);stroke-width:2}svg.pins line.unused{stroke:var(--line);stroke-width:2;stroke-dasharray:3 3}
svg.pins rect.used{fill:var(--signal)}svg.pins rect.unused{fill:var(--line)}
svg.pins .pn{font:11.5px var(--mono);fill:var(--ink)}
ol.flow{list-style:none;padding:0;display:grid;gap:2px;background:var(--surface);border-radius:var(--r);padding:var(--sp-2)}
.fstep{display:grid;grid-template-columns:3em minmax(10em,16em) 1fr;gap:var(--sp-3);align-items:baseline;padding:7px 10px;border-radius:6px;font-size:var(--fs-2)}
.fstep .fk{font-weight:600;color:var(--control);font-variant-numeric:tabular-nums;text-align:right}
.fstep.quiet{color:var(--ink2)}.fstep.quiet .fk{color:var(--dim)}.fstep .fn{font-weight:600}.fstep .fd{color:var(--ink2)}
.fstep:not(.quiet){background:var(--raised)}
footer{background:var(--surface);padding:var(--sp-5) 0 var(--sp-6);color:var(--ink2);font-size:var(--fs-1)}
footer p{max-width:90ch}
@media (max-width:980px){.explorer{grid-template-columns:1fr}.explorer .diestage{min-height:0;aspect-ratio:1/1}.split{grid-template-columns:1fr}}
@media (max-width:760px){:root{--bar:0px}.top{position:static}.top .wrap{gap:6px 10px;padding-top:8px;padding-bottom:6px}
 nav.tabs{order:3;flex:1 1 100%;gap:2px 4px}nav.tabs a{white-space:nowrap}
 .theme{margin-left:auto}html{scroll-padding-top:8px}.wrap{padding-left:16px;padding-right:16px}
 .step{align-items:flex-end;justify-content:center;padding:0 16px 24px}
 .stepcard{width:100%}.intro{padding-bottom:var(--sp-5)}.lede{font-size:var(--fs-3)}
 .scalebar{left:18px;bottom:16px}.lane-hud{left:18px;top:14px}.coords{display:none}.zoombtns{right:12px;top:12px}}
@media (max-width:640px){.fstep{grid-template-columns:2.4em 1fr}.fstep .fd{grid-column:2}nav.tabs a{padding:6px 8px;font-size:14px}}
@media (prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}
 .btn:active,.controls button:active,.tourstep:active,.theme button:active,.zoombtns button:active,.excontrols button:active{transform:none}
 .costs .bar{transition:none}.js section.panel.enter{animation:none}.scrollcue span{animation:none}
 .js .step.armed .stepcard{clip-path:none}.diestate .bar i{animation:none;width:100%}}
@media print{.top,.controls,.theme,.zoombtns{display:none}.js section.panel[hidden]{display:block}body{background:#fff}.diestage{position:static}}
"""

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HYDRA-130 Silicon Atlas</title>
<meta name="description" content="HYDRA-130: a hardware scheduler that costs compute engines, dispatches to the cheapest eligible one and calibrates itself. Blocks, builds, recorded traces and evidence, generated from the repository.">
<style>
{fonts}
:root{{{light}}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{{dark}}}}}
:root[data-theme="dark"]{{{dark}}}
.mask{{{dark}}}
{css}
</style>
</head>
<body>
{icons}
<a class="skip" href="#main">Skip to content</a>
<header class="top mask"><div class="wrap">
  <a class="brand" href="#overview"><svg aria-hidden="true"><use href="#i-mark"/></svg>HYDRA-130 <small>Silicon Atlas</small></a>
  <nav class="tabs" aria-label="Sections">
    <a href="#overview">Overview</a><a href="#architecture">Architecture</a><a href="#layout">Physical layout</a>
    <a href="#blocks">Blocks</a><a href="#demos">Demos</a><a href="#tile">Tiny Tapeout</a>
    <a href="#build">Build</a><a href="#evidence">Evidence</a>
  </nav>
  <div class="theme" role="group" aria-label="Colour theme">
    <button type="button" data-theme="system" aria-pressed="true">Auto</button>
    <button type="button" data-theme="light" aria-pressed="false">Light</button>
    <button type="button" data-theme="dark" aria-pressed="false">Dark</button>
  </div>
</div></header>

<main id="main">
{stale}

<section class="panel" id="overview" aria-labelledby="h-overview">
  <div class="story mask" id="story">
    <div class="diestage" id="hero-stage"><i class="mk tl"></i><i class="mk tr"></i><i class="mk bl"></i><i class="mk br"></i>
      <canvas id="die-hero" role="img" aria-label="The tile's routed layout from the {die_ver} harden. The steps beside it describe what each view shows."></canvas>
      <img class="still" src="media/layout.png" alt="The tile's real layout, every cell and wire, rendered from its hardened GDS by Tiny Tapeout's own tool">
      <div class="diestate" id="hero-state" role="status"></div>
      <div class="scalebar" id="hero-scale" aria-hidden="true"><span></span><b></b></div>
      <div class="dielabels" id="hero-labels" aria-hidden="true"></div>
      <div class="cellmark" id="hero-target" aria-hidden="true"><i></i><i></i><i></i><i></i></div>
      <div class="layerlabels" id="hero-layers" aria-hidden="true"></div>
      <div class="lane-hud" id="hero-hud" aria-hidden="true"></div>
    </div>
    <div class="intro wrap">
      <h1 id="h-overview">HYDRA-130</h1>
      <p class="lede">A hardware scheduler that predicts how long each compute engine would take a job, sends the job
      to the cheapest engine allowed to run it, measures what really happened and corrects its own model.</p>
      <p class="scrollcue" aria-hidden="true"><span></span>Scroll to zoom into the hardened tile</p>
    </div>
    <div class="steps">{story}</div>
  </div>
  {marquee}
  <div class="bignums">{bignums}</div>
  {marquee}

  <div class="band mask"><div class="wrap">
  <h2>Where things stand</h2>
  <p class="callout"><b>Status by revision.</b> The Tiny Tapeout tile {tile_ver} is the scheduler alone and has a clean
  sign-off record from one harden; it is not fabricated or tested silicon. The full OpenFrame chip is simulated and has never
  been hardened. No FPGA image has run on a board. Security blocks are checked IP in no build.</p>
  <div class="actions">
    <a class="btn" href="#architecture">Explore the architecture</a>
    <a class="textlink" href="#demos">Run a demo</a>
    <a class="textlink" href="#build">Build it</a>
    <a class="textlink" href="#evidence">See the evidence</a>
  </div>
  <div class="split">
  <div><h2>The decision, in numbers</h2>
  <p class="muted">The second decision of the same recorded run, as the cost engine scored it.</p></div>
  {hero_fig}
  </div>
  </div></div>
  <div class="wrap">
  <h2>A short tour of one decision</h2>
  <p class="muted">Numbers from a recorded run of the tile's own test <code>test_roofline_crossover</code>. Select a step to replay it.</p>
  <ol class="tour">{tour}</ol>
  </div>
  <div class="band mask"><div class="wrap">
  <h2 id="fpga-h">The FPGA image, in action</h2>
  <p class="muted"><span class="kind">Recorded RTL Trace</span> No HYDRA image has run on a board yet, so this is a simulation:
  the RTL of the {fpga_plan} image, driven through its serial port by its own testbench (<code>make memboard</code>) and
  replayed byte for byte. Matrices go in, the scheduler sends one job to the systolic array, the results come back out.</p>
  <div class="fpga">
    <div class="fpgastage"><svg id="fpga" viewBox="0 0 1200 480" role="img" aria-labelledby="fpga-h fpga-cap"></svg></div>
    <div class="fpgaside">
      <div class="controls" role="group" aria-label="Replay">
        <button type="button" id="fpga-prev" aria-label="Previous step"><svg aria-hidden="true"><use href="#i-prev"/></svg></button>
        <button type="button" id="fpga-play" aria-pressed="false" aria-label="Play"><svg aria-hidden="true"><use href="#i-play"/></svg></button>
        <button type="button" id="fpga-next" aria-label="Next step"><svg aria-hidden="true"><use href="#i-next"/></svg></button>
        <input type="range" id="fpga-scrub" min="0" max="1" value="0" aria-label="Step">
        <span class="clock" id="fpga-clock"></span></div>
      <p class="caption" id="fpga-cap" aria-live="polite">Scripting is needed to replay the run; every step is listed below.</p>
      <h4>Place and route of this image</h4>
      <p class="small"><span class="kind">Recorded Tool Output</span> nextpnr, from <code>docs/metrics.json</code></p>
      <dl class="pnr" id="fpga-pnr"></dl>
    </div>
  </div>
  <p class="prov" id="fpga-prov"></p>
  {fpga_text}
  </div></div>
  <div class="wrap">
  <h2>Three targets, kept apart</h2>
  <p class="muted">Each target has its own evidence. Nothing proved for one is claimed for another.</p>
  <div class="targets">{status}</div>
  <p class="muted">{n_blocks} blocks, {n_builds} builds read from the compiler, {n_traces} recorded traces.</p>
  </div>
</section>

<section class="panel wrap" id="architecture" aria-labelledby="h-arch">
  <h2 id="h-arch">Logical architecture</h2>
  <p>Pick a build. A box is drawn only if its module was elaborated when that build's own make target or plan was
  compiled (<code>tools/atlas_derive.py</code>). <b>Positions are logical, not die locations</b>; where cells really
  are is the <a href="#layout">Physical layout</a> tab. Select a box for its card.</p>
  <div class="toolbar"><label for="buildsel">Build</label><select id="buildsel">{build_opts}</select></div>
  <ul class="legend" aria-label="Colour key">
    <li class="r-signal">{i_signal}Signal: data and requests</li>
    <li class="r-control">{i_control}Control: decisions, registers, timing</li>
    <li class="r-compute">{i_compute}Compute: engines</li>
    <li class="r-memory">{i_memory}Memory: banks and streamers</li>
    <li class="r-secure">{i_secure}Security IP</li>
  </ul>
  {views}
</section>

<section class="panel wrap" id="layout" aria-labelledby="h-layout">
  <h2 id="h-layout">The tile's layout, wire by wire</h2>
  {phys_note}
  <p>Every cell, wire and via of the routed layout, and inside each cell the process design kit's own drawing of it.
  Wires glow while their net is high in the gate-level recording below. Scroll or pinch to zoom, drag to move, select
  a wire to name its net, or find one by name. Keys: arrows move, <kbd>+</kbd> and <kbd>−</kbd> zoom, <kbd>0</kbd> fits.</p>
  <div class="explorer mask" id="explorer">
    <div class="diestage" id="ex-stage"><i class="mk tl"></i><i class="mk tr"></i><i class="mk bl"></i><i class="mk br"></i>
      <canvas id="die-ex" tabindex="0" role="img" aria-label="Interactive layout of the tile. The panel beside it describes the selected net; the layout as text is below."></canvas>
      <img class="still" src="media/layout.png" alt="The tile's real layout, rendered from its hardened GDS by Tiny Tapeout's own tool" loading="lazy">
      <div class="diestate" id="ex-state" role="status"></div>
      <div class="scalebar" id="ex-scale" aria-hidden="true"><span></span><b></b></div>
      <div class="dielabels" id="ex-labels" aria-hidden="true"></div>
      <div class="coords" id="ex-xy" aria-hidden="true"></div>
      <div class="zoombtns" role="group" aria-label="Zoom">
        <button type="button" id="ex-in" aria-label="Zoom in">+</button><button type="button" id="ex-out" aria-label="Zoom out">−</button>
        <button type="button" id="ex-fit" aria-label="Fit the whole tile">Fit</button>
        <button type="button" id="ex-3d" aria-pressed="false" aria-label="Pull the layers apart in 3D">3D</button></div>
    </div>
    <div class="exside">
      <div class="excontrols" role="group" aria-label="Gate-level recording">
        <button type="button" id="ex-play" aria-pressed="false" aria-label="Play"><svg aria-hidden="true"><use href="#i-play"/></svg></button>
        <input type="range" id="ex-cycle" min="0" max="1" value="0" aria-label="Cycle of the gate-level recording">
        <span class="clock" id="ex-clock"></span></div>
      <p class="excap" id="ex-cap" aria-live="polite"></p>
      <label class="find" for="ex-find">Find a net by name</label>
      <input id="ex-find" list="ex-nets" placeholder="u_mom.u_sb.busy[0][0]" autocomplete="off" spellcheck="false">
      <datalist id="ex-nets"></datalist>
      <div class="netinfo" id="ex-net" aria-live="polite"><p class="muted">Select a wire to see its net.</p></div>
      <fieldset class="layers"><legend>Show</legend><div id="ex-layers"></div></fieldset>
      <label class="focus"><input type="checkbox" id="ex-focus"> Colour the dispatch unit's cells</label>
      <ul class="modlegend" id="ex-mods"></ul>
    </div>
  </div>
  <p class="prov" id="ex-prov"></p>
  {die_text}
  <figure class="film still-fig"><img src="media/layout.png" alt="The tile's real layout, every cell and wire, rendered from its hardened GDS by Tiny Tapeout's own tool" loading="lazy">
  <figcaption>The same run rendered from its GDS by Tiny Tapeout's own tool (<code>make render-layout</code>), for comparison.</figcaption></figure>
</section>

<section class="panel wrap" id="blocks" aria-labelledby="h-blocks">
  <h2 id="h-blocks">Every block</h2>
  <p>Each card says what the block is for, its ports, clock and reset, a worked example, how it fails or pushes back,
  which builds contain it, a permanent link to its source and the checks that exercise it. The expert view adds widths,
  registers, timing and the assumptions of its proofs, with file and line for every statement.</p>
  <div class="cardfilters toolbar">
    <label for="cfrole">Kind</label><select id="cfrole"><option value="">all</option><option>signal</option><option>control</option>
    <option>compute</option><option>memory</option><option>secure</option></select>
    <label for="cfbuild">In build</label><select id="cfbuild"><option value="">any or none</option>{build_opts}<option value="none">in no build</option></select>
  </div>
  <p class="muted">Cards were written from the RTL at commit {cited_repo} (tile {cited_tile}); a card whose file
  changed since says so beside its citations.</p>
  <div class="cards">{cards}</div>
</section>

<section class="panel wrap" id="demos" aria-labelledby="h-demos">
  <h2 id="h-demos">Demos, replayed from recorded runs</h2>
  <p class="muted">Every replay says what kind of evidence it is. Motion between two recorded samples is presentation, not
  extra hardware cycles: the cycle counter shows only recorded cycles.</p>
  <details class="textalt"><summary>What the labels mean</summary><ul class="labels">{labels}</ul></details>
  <div class="player" id="player">
    <div class="phead"><label for="tracesel">Trace</label><select id="tracesel"></select><span class="kind" id="tkind"></span></div>
    <p class="prov" id="tprov"></p>
    <div class="controls" role="group" aria-label="Playback">
      <button type="button" id="b-reset" aria-label="Back to the start"><svg aria-hidden="true"><use href="#i-first"/></svg></button>
      <button type="button" id="b-prev" aria-label="Previous event"><svg aria-hidden="true"><use href="#i-prev"/></svg></button>
      <button type="button" id="b-cm" aria-label="One cycle back">−1</button>
      <button type="button" id="b-play" aria-pressed="false" aria-label="Play"><svg aria-hidden="true"><use href="#i-play"/></svg></button>
      <button type="button" id="b-cp" aria-label="One cycle forward">+1</button>
      <button type="button" id="b-next" aria-label="Next event"><svg aria-hidden="true"><use href="#i-next"/></svg></button>
      <label for="speed" class="muted">Speed</label>
      <select id="speed"><option value="0.5">0.5×</option><option value="1" selected>1×</option><option value="2">2×</option><option value="4">4×</option></select>
      <input type="range" id="scrub" min="0" max="1" value="0" aria-label="Cycle">
      <span class="clock" id="clock" aria-live="off"></span>
    </div>
    <div class="caption" id="caption" aria-live="polite"></div>
    <div id="engpanel" hidden></div>
    <div id="tilepanels">
    <div class="scroll" style="margin-top:10px"><svg class="stage" id="stage" viewBox="0 0 980 112" role="img" aria-label="Pipeline stages; the active one is described in the caption"></svg></div>
    <div class="grid2" style="margin-top:10px">
      <div><h4>Engine costs and why each lost</h4><div class="tablewrap"><table class="costs" id="costs"><thead><tr><th>Engine</th><th class="num">Cost</th><th></th><th>Outcome</th></tr></thead><tbody></tbody></table></div>
        <h4>Tags</h4><div class="tags" id="tags"></div></div>
      <div><h4>SPI frame</h4><div id="spi" class="bytes"></div>
        <h4>Calibration</h4><div id="cal"></div></div>
    </div>
    </div>
    <h4>Waveforms around the cursor</h4>
    <div class="scroll"><svg class="wave" id="wave" viewBox="0 0 980 300" role="img" aria-label="Recorded waveforms near the current cycle"></svg></div>
    <details class="textalt"><summary>Every event in this trace, as text</summary><ol id="evlist"></ol></details>
  </div>
  {videos}
</section>

<section class="panel wrap" id="tile" aria-labelledby="h-tile">
  <h2 id="h-tile">The Tiny Tapeout tile</h2>
  <p>The tile is the scheduler and nothing else: no CPU, GPU, TPU or security hardware. Work and completions are
  <b>outside</b> it: the host sends a descriptor, reads the decision, and reports when the job finished with COMP. The
  pins below are read from <code>info.yaml</code> and checked against the wrapper's own assignments.</p>
  <div class="scroll">{pin_svg}</div>
  <div class="grid2">
    <div><h4>Clock, reset, enable</h4><ul>
      <li><b>Clock</b>: {clock_mhz} MHz declared (<code>clock_hz</code>), {period} ns, the sign-off period of {tile_ver}.</li>
      <li><b>Reset</b>: <code>rst_n</code> is asynchronous in, released synchronously by a two-flop synchroniser, so the
      design leaves reset on a clock edge.</li>
      <li><b>Enable</b>: <code>ena</code> is not used by the design.</li>
      <li><b>Idle levels</b>: CSn idles high; SCK idles low (mode 0); unused inputs are ignored; every <code>uio</code> pin is an output.</li>
      <li><b>SPI</b>: SCK at most clk/8, oversampled by the system clock. {frame}.</li></ul></div>
    <div><h4>Pins</h4><div class="tablewrap"><table><thead><tr><th>Pin</th><th>Dir</th><th>Driven by</th><th>info.yaml</th></tr></thead><tbody>{pin_rows}</tbody></table></div></div>
  </div>
  <h3 style="margin-top:20px">Register map, from the decode</h3>
  <div class="tablewrap"><table><thead><tr><th>Address</th><th>Name</th><th class="num">Bytes</th><th>Access</th><th>Fields</th></tr></thead><tbody>{reg_rows}</tbody></table></div>
  <div class="grid2"><div><h4>STATUS bits</h4><div class="tablewrap"><table><tbody>{status_bits}</tbody></table></div></div>
  <div><h4>RESULT bits</h4><div class="tablewrap"><table><tbody>{result_bits}</tbody></table></div></div></div>
  <h3 style="margin-top:20px">A worked SPI session</h3>
  <p>The frames below are the real bytes of two recorded tests: a descriptor staged and dispatched, and a malformed frame refused.</p>
  <div id="worked"></div>
</section>

<section class="panel wrap" id="build" aria-labelledby="h-build">
  <h2 id="h-build">From RTL to layout</h2>
  {flow}
  <h3>Reproduce</h3>
  <pre><code>cd ~/src/hydra-skywater130 && make verify        # the whole suite: simulation, proofs, lint
cd ~/src/hydra-skywater130 && make tile tile-gl     # tile tests on RTL, then on the hardened netlist
cd ~/src/hydra-skywater130 && make harden           # LibreLane on the tile (unattended)
cd ~/src/hydra-skywater130 && make atlas site       # re-derive builds, re-record traces, rebuild this page</code></pre>
  <p>The page is static: GitHub Pages serves <code>docs/site/</code> through <code>.github/workflows/pages.yml</code>
  once Pages is set to "GitHub Actions" in the repository settings. Nothing runs in the browser but replay.</p>
</section>

<section class="panel wrap" id="evidence" aria-labelledby="h-ev">
  <h2 id="h-ev">Evidence</h2>
  <p>Each check names the command that reproduces it. A proof establishes its property under its stated assumptions
  and nothing wider; a simulation establishes agreement on the tested inputs.</p>
  <div class="tablewrap"><table><thead><tr><th>Check</th><th class="num">Scale</th><th>Kind</th><th>Run with</th></tr></thead><tbody>{ver_rows}</tbody></table></div>
  <h3>Recorded traces on this page</h3>
  <div class="tablewrap"><table><thead><tr><th>Trace</th><th>Label</th><th>Test</th><th>Result</th><th>Commit</th></tr></thead><tbody>{trace_rows}</tbody></table></div>
  <h3>Where the documents and the RTL disagree</h3>
  <p>Found while writing the cards, by reading the RTL and, where marked VERIFIED-SIM, by simulation. The atlas, the
  READMEs and the figures follow the RTL; the RTL, its comments and the other documents are not changed by this work.</p>
  <div class="tablewrap"><table><thead><tr><th>Claim</th><th>What the RTL does</th><th>Status</th></tr></thead><tbody>{contra_rows}</tbody></table></div>
  <h3>Not done</h3><ul>{pend}</ul>
</section>
</main>

<footer class="mask"><div class="wrap">
  <p>Maintained by <a href="https://github.com/Normansrule">@Normansrule</a>. Apache 2.0; board files and submodules keep their own licences (see NOTICE).
  Generated by <code>tools/gen_site.py</code> from <code>docs/atlas/</code>, <code>docs/metrics.json</code>, <code>docs/timing.json</code>
  and the tile's RTL; <code>make site-check</code> fails if this page is out of date. Source: <a href="https://github.com/{repo}">{repo}</a>.</p>
</div></footer>
<script id="atlas-data" type="application/json">{data}</script>
<script id="die-bin" type="application/octet-stream">{die_bin}</script>
<script id="diegl-bin" type="application/octet-stream">{diegl_bin}</script>
<script>{js}</script>
</body>
</html>
"""

JS = r"""
(()=>{
const D=JSON.parse(document.getElementById('atlas-data').textContent);
document.documentElement.classList.add('js');
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;
const css=n=>getComputedStyle(document.documentElement).getPropertyValue('--'+n).trim();
// ---------- theme
function setTheme(t){try{localStorage.setItem('atlas-theme',t)}catch(e){}
  if(t==='system')document.documentElement.removeAttribute('data-theme');else document.documentElement.setAttribute('data-theme',t);
  $$('.theme button').forEach(b=>b.setAttribute('aria-pressed',b.dataset.theme===t));renderAll();}
$$('.theme button').forEach(b=>b.onclick=()=>setTheme(b.dataset.theme));
// ---------- tabs (hash routing)
const panels=$$('section.panel'), links=$$('nav.tabs a');let routed=false;
function route(){let id=(location.hash||'#overview').slice(1);let target=null,deep=null;
  if(id.startsWith('card-')){target=id;id='blocks'}
  // deep links into the player: #demos/<trace>/<cycle>
  if(id.startsWith('demos/')){deep=id.split('/');id='demos'}
  if(!panels.some(p=>p.id===id))id='overview';
  panels.forEach(p=>p.hidden=p.id!==id);links.forEach(a=>a.setAttribute('aria-current',a.getAttribute('href')==='#'+id?'page':'false'));
  if(target){const c=document.getElementById(target);if(c){c.querySelector('details.more').open=true;c.scrollIntoView();c.classList.add('flash');setTimeout(()=>c.classList.remove('flash'),1600)}}
  else window.scrollTo(0,0);
  if(id==='demos')renderAll();
  const pn=panels.find(p=>p.id===id);if(routed&&pn){pn.classList.remove('enter');void pn.offsetWidth;pn.classList.add('enter')}routed=true;
  if(deep&&T[deep[1]]){tsel.value=deep[1];load(deep[1]);if(deep[2])goto(+deep[2])}}
addEventListener('hashchange',route);
// ---------- build switcher + node clicks
const bsel=$('#buildsel');
function showBuild(){$$('.lview').forEach(f=>f.hidden=f.dataset.build!==bsel.value)}
bsel.onchange=showBuild;showBuild();
$$('.node').forEach(n=>{const go=()=>{location.hash='card-'+n.dataset.id};
  n.onclick=go;n.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();go()}};
  const svg=n.closest('svg');const hot=on=>svg.querySelectorAll('.edge').forEach(e=>{if(e.dataset.a===n.dataset.id||e.dataset.b===n.dataset.id)e.classList.toggle('hot',on)});
  n.onmouseenter=n.onfocus=()=>hot(true);n.onmouseleave=n.onblur=()=>hot(false);});
// ---------- card filters
const fr=$('#cfrole'),fb=$('#cfbuild');
function filt(){$$('.card').forEach(c=>{const r=!fr.value||c.dataset.role===fr.value;const bs=c.dataset.builds.split(' ').filter(Boolean);
  const b=!fb.value||(fb.value==='none'?bs.length===0:bs.includes(fb.value));c.hidden=!(r&&b)})}
fr.onchange=fb.onchange=filt;
// ---------- trace player
const T=D.traces, tsel=$('#tracesel');
const ENG=n=>({ENG_CPU:'CPU',ENG_SIMD:'Vector unit',ENG_TPU:'Systolic array',ENG_NTT:'Butterflies',ENG_CRYPTO:'Crypto slot',ENG_GPU:'GPU'}[n]||n);
[['Scheduler on the Tiny Tapeout tile',id=>!T[id].view||T[id].view==='tile'],['Engines and IP, chip-side tests',id=>T[id].view&&T[id].view!=='tile']].forEach(([lab,f])=>{
  const g=document.createElement('optgroup');g.label=lab;Object.keys(T).filter(f).forEach(id=>{const o=document.createElement('option');o.value=id;o.textContent=T[id].title;g.appendChild(o)});if(g.children.length)tsel.appendChild(g)});
let tr=null,cyc=0,ei=-1,timer=null,speed=1;
const pad=(n,w)=>String(n).padStart(w,' ');
function regname(a){return D.regs[a]||('0x'+a.toString(16))}
function describe(e){
  switch(e.k){
  case 'spi':{if(!e.bytes.length)return 'An empty frame: CSn pulsed low with no bytes. Not an error.';
    const n=e.bytes.length-1, want=D.reglen[e.addr];
    const what=e.rd?`a read of ${regname(e.addr)}`:`a write of ${n} byte${n===1?'':'s'} to ${regname(e.addr)}`;
    let v=e.rd?' '+readValue(e):(e.ok?' Exactly the register length arrived, so it commits when CSn rises.':
      (e.bad?` Refused at CSn rise: ${want===undefined?'no such register':(want===0?'not writable':(n!==want?`${n} bytes, the register takes ${want}`:'not writable'))}. FRAME_ERR is set and nothing changes.`:''));
    return `SPI frame, ${e.bytes.length} bytes: ${what}.`+v}
  case 'go':return e.accepted?'GO: the staged descriptor is presented to the scheduler.':'GO refused: no complete descriptor is staged (GO_ERR).';
  case 'desc':return `The scheduler takes the descriptor: ${e.op.replace('OPC_','')} on ${e.dtype.replace('DT_','')}, ${e.m}×${e.n}×${e.kk}, ${e.bytes} bytes of operands.`;
  case 'feat':return `Features: log₂ of the work = ${e.lg_w}, log₂ of arithmetic intensity = ${e.lg_i}.`;
  case 'lane':return e.capable?`Cost engine, row ${e.eng} (${ENG(e.name)}): predicted ${e.tpred} cycles, cost ${e.cost}, calibration factor ${e.kf}/64${e.qd?`, ${e.qd} queued`:''}.`:
    `Cost engine, row ${e.eng} (${ENG(e.name)}): cannot ${!e.opc_ok?'perform this operation':''}${!e.opc_ok&&!e.dt_ok?' or ':''}${!e.dt_ok?'represent this data type':''}. Excluded before any cost is compared.`;
  case 'select':{if(!e.ok&&e.unsupported)return 'No engine can run this descriptor: it is reported as unsupported and retired, not retried.';
    if(!e.ok)return 'No engine is selectable this cycle; the descriptor waits.';
    const w=e.rows.find(r=>r.chosen);const s=e.rows.filter(r=>!r.chosen&&r.why==='higher cost').sort((a,b)=>a.cost-b.cost)[0];
    return `Select: ${ENG(w.name)} at cost ${w.cost}`+(s?`, ahead of ${ENG(s.name)} at ${s.cost} (margin ${e.margin}).`:'.')}
  case 'tag':return `Dispatched to ${ENG(D.traces[tsel.value].enums.engine_e[e.eng])} with tag ${e.tag}. Tags now in flight: ${tagstr(e.busy_after)}.`;
  case 'comp':return e.stale?`Completion for tag ${e.tag}, which is not in flight: flagged STALE, nothing freed, no calibration sample.`:
    `Completion for tag ${e.tag}: the tag is free again.`;
  case 'cal':return e.update?`Calibration: ${ENG(e.name)} took ${e.meas} cycles against ${e.pred} predicted, so its factor moves ${e.k_cur} → ${e.k_next} (64 is exact; step k/16, clamped).`:
    `Calibration sample for ${ENG(e.name)}: no update (frozen, or within tolerance).`;
  case 'stall':return 'Back-pressure: the scheduler is not ready for another descriptor this cycle.';
  case 'notag':return 'No tag is free: the decision is held until a completion frees one.';
  case 'unsupported':return 'Unsupported descriptor reported (STATUS.UNSUPPORTED, IRQ).';
  case 'reset':return e.level==='0'?'Reset asserted (rst_n low).':'Reset released at the pin; the synchroniser releases the design on a later clock edge.';
  case 'rise':return `${sname(e.sig)} rises.`;
  case 'state':return `${sname(e.sig)} becomes ${tr.meta.states?tr.meta.states.names[parseInt(e.v,16)]:e.v}.`;
  case 'reset_sync':return e.level==='0'?'The design is in reset.':'The synchroniser releases the design: two clean clock edges after rst_n rose.';
  }return e.k}
// A read returns the register MSB first on CIPO bytes 1..N (byte 0 echoes STATUS[15:8]).
function readValue(e){const n=D.reglen[e.addr]||0;const b=e.cipo.slice(1,1+n);if(!n||b.length<n)return 'An unmapped register reads 0.';
  let v=0n;b.forEach(x=>v=(v<<8n)|BigInt(x));const bits=(f)=>Number((v>>BigInt(f[2]))&((1n<<BigInt(f[1]-f[2]+1))-1n));
  const name=regname(e.addr);
  if(name==='STATUS'){const on=D.status_bits.filter(f=>!/^\d/.test(f[0])&&bits(f)).map(f=>({wd_ready:'ready',any_busy:'busy',pending_q:'pending',wd_ok:'WD_OK',s_disp:'dispatched',s_unsupp:'unsupported',s_stale:'stale',s_frame:'frame error',s_goerr:'GO error',fence_busy:'fence busy',param_lock_q:'PARAM_LOCK',hold_q:'HOLD',cal_freeze_q:'CAL_FREEZE',cal_reset_q:'CAL_RESET'}[f[0]]||f[0]));return `STATUS = 0x${v.toString(16).padStart(4,'0')}: ${on.join(', ')||'nothing set'}.`}
  if(name==='RESULT'){const g=k=>bits(D.result_bits.find(f=>f[0]===k));const eng=D.traces[tsel.value].enums.engine_e[g('r_engine')];
    return `RESULT: engine ${ENG(eng)}, tag ${g('r_tag')}, margin ${g('r_margin')}, error tag ${g('r_errtag')}.`}
  if(name==='BUSY')return `BUSY: tags in flight ${tagstr(Number(v))}.`;
  if(name==='ID')return `ID = 0x${v.toString(16)} ("${b.map(x=>String.fromCharCode(x)).join('')}").`;
  return `${name} = 0x${v.toString(16)}.`}
function tagstr(b){if(b==null)return '?';let s=[];for(let i=0;i<4;i++)if(b>>i&1)s.push(i);return s.length?s.join(', '):'none'}
function load(id){tr=T[id];cyc=0;ei=-1;stop();$('#tkind').textContent=tr.label;
  $('#tprov').textContent=`${tr.result} · ${tr.test} · ${tr.command} · ${tr.tile_commit?'tile '+String(tr.tile_commit).slice(0,10):'repo '+String(tr.repo_commit).slice(0,10)} · ${tr.tools.iverilog}${tr.tools.cocotb&&tr.tile_commit?' · cocotb '+tr.tools.cocotb:''} · ${tr.cycles.toLocaleString()} cycles of ${tr.clock_ns} ns`;
  const sc=$('#scrub');sc.max=tr.cycles-1;sc.value=0;
  const ol=$('#evlist');ol.innerHTML='';tr.events.forEach(e=>{const li=document.createElement('li');li.textContent=`cycle ${e.c}: ${describe(e)}`;ol.appendChild(li)});
  renderAll()}
tsel.onchange=()=>load(tsel.value);
function evAt(c){let i=-1;for(let j=0;j<tr.events.length;j++){if(tr.events[j].c<=c)i=j;else break}return i}
function sig(name,c){const s=tr.signals[name];if(!s)return null;let v=null;for(const [cc,x] of s.v){if(cc>c)break;v=x}return v==='x'?null:(v==null?null:parseInt(v,16))}
const STAGES=[['spi','SPI','bytes in'],['regs','Registers','descriptor'],['feat','Features','log₂ work'],['cost','Cost engine','row by row'],
  ['select','Select','cheapest capable'],['sb','Scoreboard','tags'],['comp','Completion','from the host'],['cal','Calibration','k factors']];
const STAGE_OF={spi:'spi',go:'regs',desc:'regs',feat:'feat',lane:'cost',select:'select',tag:'sb',notag:'sb',comp:'comp',cal:'cal',stall:'regs',unsupported:'select',reset:'regs',reset_sync:'regs'};
function renderStage(e){const sv=$('#stage');const w=110,g=12;let s='';
  STAGES.forEach(([k,a,b],i)=>{const x=10+i*(w+g);const on=e&&STAGE_OF[e.k]===k;
    if(i)s+=`<path class="sedge${on?' on':''}" d="M${x-g} 59H${x}"/>`;
    s+=`<g class="st r-${k==='cost'||k==='select'||k==='sb'||k==='cal'||k==='regs'?'control':'signal'}${on?' on':''}"><rect x="${x}" y="34" width="${w}" height="50" rx="8"/>`+
      `<text x="${x+w/2}" y="55">${a}</text><text class="sub" x="${x+w/2}" y="72">${b}</text></g>`});
  if(e&&e.k==='lane'){const x=10+3*(w+g);s+=`<text class="sub" x="${x+w/2}" y="24" text-anchor="middle" style="font:11px var(--mono);fill:var(--control)">row ${e.eng}</text>`}
  sv.innerHTML=s}
function lastOf(k,i){for(let j=i;j>=0;j--)if(tr.events[j].k===k)return tr.events[j];return null}
function renderCosts(i){const tb=$('#costs tbody');const sel=lastOf('select',i);
  // the sweep in progress: lanes after the last select
  let rows=[];const lanes=[];for(let j=i;j>=0;j--){const e=tr.events[j];if(e.k==='select')break;if(e.k==='lane')lanes.unshift(e)}
  if(lanes.length)rows=lanes.map(l=>({name:l.name,cost:l.capable?l.cost:null,why:l.capable?'costed':'cannot do this operation or data type',chosen:false,pending:true}));
  else if(sel)rows=sel.rows;
  const max=Math.max(1,...rows.filter(r=>r.cost!=null&&r.why!=='cannot do this operation or data type').map(r=>r.cost));
  tb.innerHTML=rows.map(r=>{const rej=r.why==='cannot do this operation or data type'||r.why==='not eligible';
    const cost=rej?'—':r.cost;const bw=rej?0:Math.max(2,Math.round(140*r.cost/max));
    const mark=r.chosen?'<svg aria-label="chosen" role="img"><use href="#i-check"/></svg>':(rej?'<svg aria-label="refused" role="img"><use href="#i-cross"/></svg>':'');
    return `<tr class="${r.chosen?'win':(rej?'rej':'')}"><td>${mark}${ENG(r.name)}</td><td class="num">${cost}</td><td><span class="bar" style="width:${bw}px"></span></td><td class="why">${r.chosen?'chosen':(r.pending?'swept, waiting for select':(r.why||''))}</td></tr>`}).join('')||'<tr><td colspan="4" class="muted">No decision yet.</td></tr>'}
function renderTags(i){let b=sig('tag_busy',cyc);if(b==null){const t=lastOf('tag',i);b=t?t.busy_after:0}
  $('#tags').innerHTML=[0,1,2,3].map(t=>`<div class="tagc${b>>t&1?' busy':''}">tag ${t}<br>${b>>t&1?'busy':'free'}</div>`).join('')}
function hx(b){return b.map(x=>x.toString(16).padStart(2,'0')).join(' ')}
function renderSpi(i){const e=lastOf('spi',i);if(!e){$('#spi').textContent='No frame yet.';return}
  $('#spi').innerHTML=`<div>COPI: ${hx(e.bytes)}</div><div>CIPO: ${hx(e.cipo.slice(0,e.bytes.length))}</div><div class="muted" style="font-family:var(--sans);font-size:var(--fs-2);margin-top:6px">${describe(e)}</div>`}
function renderCal(i){const cal=tr.events.filter(e=>e.k==='cal'),cur=lastOf('cal',i);const box=$('#cal');
  if(!cal.length){box.innerHTML='<p class="muted">No completion in this trace.</p>';return}
  if(cal.length<3){box.innerHTML=cur?`<p>${describe(cur)}</p>`:'<p class="muted">No completion yet.</p>';return}
  // chart: chosen engine and the factor of each engine over the run
  const sels=tr.events.filter(e=>e.k==='select'&&e.ok);const W=440,Hh=170,n=sels.length;
  const ks={};cal.forEach(e=>{(ks[e.name]=ks[e.name]||[]).push(e)});
  let s=`<svg class="chart" viewBox="0 0 ${W} ${Hh}" role="img" aria-label="Calibration factor of each engine at each completion">`;
  const x=c=>30+(W-40)*c/Math.max(1,tr.cycles),y=k=>Hh-20-(Hh-40)*k/255;
  s+=`<line x1="30" x2="${W-10}" y1="${y(64)}" y2="${y(64)}" stroke="${css('line')}" stroke-dasharray="3 3"/><text x="32" y="${y(64)-4}">64 = exact</text>`;
  Object.entries(ks).forEach(([nme,arr],j)=>{const col=css(['control','compute','memory','signal','secure'][j%5]);
    s+=`<polyline fill="none" stroke="${col}" stroke-width="2" points="${arr.map(e=>x(e.c)+','+y(e.k_next)).join(' ')}"/>`+
      `<text x="${x(arr[arr.length-1].c)-4}" y="${y(arr[arr.length-1].k_next)-6}" text-anchor="end" fill="${col}">${ENG(nme)}</text>`});
  s+=`<line x1="${x(cyc)}" x2="${x(cyc)}" y1="10" y2="${Hh-20}" stroke="${css('control')}"/>`;
  s+=`<text x="30" y="${Hh-4}">cycle 0</text><text x="${W-10}" y="${Hh-4}" text-anchor="end">${tr.cycles.toLocaleString()}</text></svg>`;
  const win=sels.map(e=>ENG(e.rows.find(r=>r.chosen).name));const moved=win.findIndex(w=>w!==win[0]);
  box.innerHTML=s+`<p>${cur?describe(cur):''}</p><p class="muted">${n} dispatches: ${win[0]} for the first ${moved<0?n:moved}`+(moved<0?'.':`, then ${win[moved]}.`)+`</p>`}
// pins split into their named bits (tt_um_hydra_mom: ui[0] SCK, ui[1] COPI, ui[2] CSn, uo[0] CIPO, uo[7] ready)
function bitsig(name,bit){const S=tr.signals[name];if(!S)return null;const out=[];let last=null;
  for(const [c,v] of S.v){const b=v==='x'?'x':String((parseInt(v,16)>>bit)&1);if(b!==last){out.push([c,b]);last=b}}return {w:1,v:out}}
function waveSignals(){const v={sck:bitsig('ui_in',0),copi:bitsig('ui_in',1),csn:bitsig('ui_in',2),cipo:bitsig('uo_out',0),ready:bitsig('uo_out',7)};
  return Object.assign({},tr.signals,...Object.entries(v).filter(([k,x])=>x).map(([k,x])=>({[k]:x})))}
const WAVE_LABEL={rst_n:'rst_n',rst_core:'reset (synced)',csn:'CSn  ui[2]',sck:'SCK  ui[0]',copi:'COPI ui[1]',cipo:'CIPO uo[0]',ready:'ready uo[7]',uio_out:'uio_out',spi_rx_valid:'byte in',reg_wd_ok:'WD_OK',wd_valid:'wd_valid',wd_ready:'wd_ready',eval_busy:'sweeping',idx:'row',lane_we:'row done',c_valid:'costs ready',sel_eng:'chosen',sb_ready:'tag free',disp_valid:'dispatch',disp_tag:'tag',tag_busy:'tags busy',comp_valid:'completion',cal_valid:'calibrate'};
function renderWave(){const sv=$('#wave');const SIG=waveSignals();
  const names=isTile()?Object.keys(WAVE_LABEL).filter(n=>SIG[n]):Object.keys(SIG).filter(k=>!/_pkg_/.test(k)&&(SIG[k].w===1||(tr.meta.states&&k===tr.meta.states.signal)||SIG[k].w<=16)).slice(0,22);
  const LBL=n=>isTile()?WAVE_LABEL[n]:sname(n).slice(0,18);
  const W=980,lh=15,x0=120,span=96;const c0=Math.max(0,cyc-span/2),c1=c0+span;const Hh=names.length*lh+24;sv.setAttribute('viewBox',`0 0 ${W} ${Hh}`);
  const X=c=>x0+(W-x0-10)*(c-c0)/span;let s='';
  names.forEach((n,i)=>{const y=12+i*lh;const S=SIG[n];s+=`<text x="4" y="${y+9}">${LBL(n)}</text>`;
    let pts=[];let prev=null;let start=c0;
    const vals=[];let cur=null;for(const [c,v] of S.v){if(c<=c0)cur=v;else if(c<c1)vals.push([c,v])}
    const seg=[[c0,cur]].concat(vals);
    seg.forEach(([c,v],k)=>{const cn=k+1<seg.length?seg[k+1][0]:c1;const xa=X(Math.max(c,c0)),xb=X(cn);
      if(S.w===1){const yy=v==='1'?y:y+10;pts.push(`${xa},${yy}`,`${xb},${yy}`)}
      else{s+=`<polygon class="bus" points="${xa+2},${y} ${xb-2},${y} ${xb},${y+5} ${xb-2},${y+10} ${xa+2},${y+10} ${xa},${y+5}"/>`;
        if(xb-xa>24)s+=`<text x="${xa+4}" y="${y+9}" style="fill:var(--ink)">${v==null?'':v}</text>`}});
    if(S.w===1)s+=`<polyline class="w" points="${pts.join(' ')}"/>`});
  s+=`<line class="cur" x1="${X(cyc)}" x2="${X(cyc)}" y1="4" y2="${Hh-14}"/><text x="${x0}" y="${Hh-2}">cycle ${Math.round(c0)}</text><text x="${W-10}" y="${Hh-2}" text-anchor="end">${Math.round(c1)}</text>`;
  sv.innerHTML=s}
// ---------- engine traces: the array, the lanes, and plain register views
const isTile=()=>!tr.view||tr.view==='tile';
const sname=k=>k.replace(/^dut\./,'').replace(/^u_lanes\.g_bfly\[0\]\.u_bf\./,'lane 0 butterfly: ').replace(/^u_ctrl\./,'controller: ');
function sv(name,c){return sig(name,c)}
function signed(v,w){if(v==null)return null;return v>=2**(w-1)?v-2**w:v}
function lanesOf(name,n,w,c){const v=tr.signals[name];if(!v)return [];let raw=null;for(const [cc,x] of v.v){if(cc>c)break;raw=x}
  if(raw==null||raw==='x')return Array(n).fill(null);const big=BigInt('0x'+raw);return [...Array(n)].map((_,i)=>Number((big>>BigInt(w*i))&((1n<<BigInt(w))-1n)))}
function stateName(c){const m=tr.meta.states;if(!m)return null;const v=sv(m.signal,c);return v==null?null:(m.names[v]||v)}
function engCaption(e,c){const st=stateName(c);
  if(tr.view==='tpu'){const m=sv('dut.u_ctrl.dim_m',c),n=sv('dut.u_ctrl.dim_n',c),k=sv('dut.u_ctrl.dim_k',c);
    const what={S_IDLE:'idle, waiting for a job',S_CLEAR:'clearing every accumulator for a new tile',S_STREAM:'streaming one slice of A and B per step; each operand pair moves one processing element per cycle',
      S_FLUSH:'flushing: zeros follow the last slice so it reaches the far corner',S_DRAIN:'draining: accumulators shift south, the bottom row goes out',S_TAIL:'sending the last results',S_DONE:'done: the tag is reported back'}[st]||st;
    return `Array controller ${st?st.replace('S_',''):''}: ${what}. Job ${m}×${n}×${k}.`+(sv('dut.res_valid',c)?` Result out: ${signed(sv('dut.res_data',c),32)}.`:'')}
  if(e&&e.k==='rise')return `${sname(e.sig)} rises.`;return st?`State ${st}.`:'Recorded values at this cycle.'}
function renderTpu(c){const N=4;let h='<div class="scroll"><svg class="tpu" viewBox="0 0 520 380" role="img" aria-label="The 4 by 4 array at this cycle: each cell shows its west and north operands and its accumulator">';
  for(let r=0;r<N;r++)for(let q=0;q<N;q++){const p=`dut.u_array.g_row[${r}].g_col[${q}].u_pe.`;const a=signed(sv(p+'a_in',c),8),b=signed(sv(p+'b_in',c),8),acc=signed(sv(p+'acc_q',c),32);
    const x=70+q*110,y=50+r*80,act=a!==0&&b!==0&&a!=null&&b!=null&&sv('dut.u_ctrl.arr_en',c);
    h+=`<g class="st r-compute${act?' on':''}"><rect x="${x}" y="${y}" width="96" height="66" rx="8"/><text x="${x+48}" y="${y+22}">acc ${acc==null?'x':acc}</text>`+
      `<text class="sub" x="${x+48}" y="${y+42}">a ${a==null?'x':a} · b ${b==null?'x':b}</text><text class="sub" x="${x+48}" y="${y+58}">PE(${r},${q})</text></g>`}
  h+=`<text class="sub" x="10" y="30" style="font:12px var(--mono);fill:var(--ink2)">A enters from the west, B from the north; one hop per enabled cycle</text></svg></div>`;
  const res=[];for(let j=0;j<=c;j++)if(sv('dut.res_valid',j))res.push(signed(sv('dut.res_data',j),32));
  h+=`<p class="bytes">Results drained so far (row-major): ${res.length?res.join(', '):'none yet'}</p>`;$('#engpanel').innerHTML=h}
function renderLanes(c){const M=tr.meta,n=M.lanes,w=M.width;const A=lanesOf(M.a,n,w,c),B=lanesOf(M.b,n,w,c);let h='<div class="tablewrap"><table><thead><tr><th>Lane</th><th>a</th><th>b</th>';
  if(M.w){const W=lanesOf(M.w,n,w,c),Y0=lanesOf(M.y0,n,w,c),Y1=lanesOf(M.y1,n,w,c);const q=sv(M.q_signal,c);
    h+='<th>w</th><th>y0 = a + b·w mod q</th><th>y1 = a − b·w mod q</th><th>Recomputed here</th></tr></thead><tbody>';
    for(let i=0;i<n;i++){let chk='';if(q&&A[i]!=null&&B[i]!=null&&W[i]!=null&&Y0[i]!=null){const qq=BigInt(q),v=BigInt(B[i])*BigInt(W[i])%qq;
      const e0=(BigInt(A[i])+v)%qq,e1=((BigInt(A[i])-v)%qq+qq)%qq;chk=(BigInt(Y0[i])===e0&&BigInt(Y1[i])===e1)?'matches':'outputs belong to an earlier input'}
      h+=`<tr><td>${i}</td><td class="num">${A[i]??'x'}</td><td class="num">${B[i]??'x'}</td><td class="num">${W[i]??'x'}</td><td class="num">${Y0[i]??'x'}</td><td class="num">${Y1[i]??'x'}</td><td>${chk}</td></tr>`}
    h+=`</tbody></table></div><p class="muted">q = ${q}. The check column recomputes the equations in your browser; the evidence is the testbench's comparison with its own model.</p>`}
  else{const Y=lanesOf(M.y,n,w,c);const op=sv(M.op,c);h+=`<th>y = ${M.ops[op]||'?'}(a, b)</th></tr></thead><tbody>`;
    for(let i=0;i<n;i++)h+=`<tr><td>${i}</td><td class="num">${signed(A[i],32)??'x'}</td><td class="num">${signed(B[i],32)??'x'}</td><td class="num">${signed(Y[i],32)??'x'}</td></tr>`;
    h+=`</tbody></table></div><p class="muted">Operation ${M.ops[op]||op}, encoded ${op}. Outputs are registered, one cycle after their inputs.</p>`}
  $('#engpanel').innerHTML=h}
function renderRegs(c){const rows=Object.keys(tr.signals).filter(k=>!/ntt_pkg|tpu_pkg/.test(k)).map(k=>{const S=tr.signals[k];const v=sv(k,c);
  return `<tr><td><code>${sname(k)}</code></td><td>${S.w}</td><td class="num">${v==null?'x':(S.w>32?'0x'+v.toString(16):v)}</td></tr>`}).join('');
  $('#engpanel').innerHTML=`<div class="tablewrap"><table><thead><tr><th>Signal</th><th>Bits</th><th>Value at this cycle</th></tr></thead><tbody>${rows}</tbody></table></div>`}
function renderAll(){if(!tr)return;const i=evAt(Math.round(cyc));ei=i;const e=i>=0?tr.events[i]:null;const c=Math.round(cyc);
  $('#clock').textContent=`cycle ${pad(c,6)} / ${tr.cycles-1}`;$('#scrub').value=c;
  $('#tilepanels').hidden=!isTile();$('#engpanel').hidden=isTile();
  if(isTile()){$('#caption').textContent=e?`Cycle ${e.c}: ${describe(e)}`:'Before the first recorded event. Press Play or step forward.';
    renderStage(e);renderCosts(i);renderTags(i);renderSpi(i);renderCal(i)}
  else{$('#caption').textContent=`Cycle ${c}: `+engCaption(e&&e.c===c?e:null,c);
    if(tr.view==='tpu')renderTpu(c);else if(tr.view==='lanes')renderLanes(c);else renderRegs(c)}
  renderWave()}
function goto(c){cyc=Math.max(0,Math.min(tr.cycles-1,c));renderAll()}
const PLAY='<svg aria-hidden="true"><use href="#i-play"/></svg>',PAUSE='<svg aria-hidden="true"><use href="#i-pause"/></svg>';
function stop(){if(timer){clearTimeout(timer);timer=null}const b=$('#b-play');b.setAttribute('aria-pressed','false');b.setAttribute('aria-label','Play');b.innerHTML=PLAY}
function step(){const n=tr.events.findIndex(e=>e.c>Math.round(cyc));if(n<0){stop();return}const target=tr.events[n].c;
  if(reduce){goto(target);timer=setTimeout(step,1500/speed);return}
  const from=cyc,t0=performance.now(),dur=Math.min(700,40+(target-from)*2)/speed;
  const anim=now=>{const f=Math.min(1,(now-t0)/dur);cyc=from+(target-from)*f;renderAll();
    if(f<1&&timer)requestAnimationFrame(anim);else if(timer){cyc=target;renderAll();timer=setTimeout(step,1400/speed)}};
  timer=setTimeout(()=>requestAnimationFrame(anim),0)}
$('#b-play').onclick=()=>{if(timer){stop();return}const b=$('#b-play');b.setAttribute('aria-pressed','true');b.setAttribute('aria-label','Pause');b.innerHTML=PAUSE;step()};
$('#b-reset').onclick=()=>{stop();goto(0)};
$('#b-next').onclick=()=>{stop();const n=tr.events.find(e=>e.c>Math.round(cyc));if(n)goto(n.c)};
$('#b-prev').onclick=()=>{stop();const p=[...tr.events].reverse().find(e=>e.c<Math.round(cyc));goto(p?p.c:0)};
$('#b-cp').onclick=()=>{stop();goto(Math.round(cyc)+1)};$('#b-cm').onclick=()=>{stop();goto(Math.round(cyc)-1)};
$('#speed').onchange=e=>speed=+e.target.value;
$('#scrub').oninput=e=>{stop();goto(+e.target.value)};
$('#player').addEventListener('keydown',e=>{if(e.target.tagName==='SELECT'||e.target.tagName==='INPUT')return;
  if(e.key==='ArrowRight'){e.preventDefault();$('#b-next').click()}if(e.key==='ArrowLeft'){e.preventDefault();$('#b-prev').click()}});
$$('.tourstep').forEach(b=>b.onclick=()=>{tsel.value=b.dataset.trace;load(b.dataset.trace);location.hash='demos';setTimeout(()=>goto(+b.dataset.cycle),0)});
// ---------- worked SPI example on the tile tab
function worked(){const box=$('#worked');const pick=[['crossover',e=>e.c<1600],['torn',e=>e.c<3000]];let h='';
  pick.forEach(([id,f])=>{const t=T[id];if(!t)return;h+=`<h4>${t.title}</h4><div class="tablewrap"><table><thead><tr><th>Cycle</th><th>COPI (host to tile)</th><th>CIPO (tile to host)</th><th>Bytes</th><th>Meaning</th></tr></thead><tbody>`;
    t.events.filter(e=>(e.k==='spi'||e.k==='go'||e.k==='tag'||e.k==='select')&&f(e)).forEach(e=>{
      h+=e.k==='spi'?`<tr><td class="num">${e.c}</td><td class="num">${hx(e.bytes)}</td><td class="num">${hx(e.cipo.slice(0,e.bytes.length))}</td><td class="num">${e.bytes.length}</td><td>${describe(e)}</td></tr>`:
        `<tr><td class="num">${e.c}</td><td colspan="3"></td><td>${describe(e)}</td></tr>`});h+='</tbody></table></div>'});box.innerHTML=h}
// ---------- start
let t0='system';try{t0=localStorage.getItem('atlas-theme')||'system'}catch(e){}
$$('.theme button').forEach(b=>b.setAttribute('aria-pressed',b.dataset.theme===t0));if(t0!=='system')document.documentElement.setAttribute('data-theme',t0);
if(Object.keys(T).length){tsel.value=T.crossover?'crossover':Object.keys(T)[0];load(tsel.value)}
worked();route();
})();
"""

DIE_JS = r"""
(()=>{
// =====================================================================
// The die view: the tile's routed layout, drawn with WebGL 2 from
// docs/atlas/die.bin, its wires lit by docs/atlas/die-gl.bin (a gate-level
// recording of one decision). Nothing here is invented: every rectangle is
// from the hardened run's DEF or the PDK's cell drawings, every lit wire is
// a net that was high in that cycle of the recorded simulation.
// =====================================================================
const D=JSON.parse(document.getElementById('atlas-data').textContent);
const DM=D.die,DG=D.diegl,PAL=D.diepal;
const $=s=>document.querySelector(s),$$=s=>[...document.querySelectorAll(s)];
const RM=matchMedia('(prefers-reduced-motion: reduce)');
const rgb=h=>[parseInt(h.slice(1,3),16)/255,parseInt(h.slice(3,5),16)/255,parseInt(h.slice(5,7),16)/255];
const ENG={ENG_CPU:'CPU',ENG_SIMD:'vector unit',ENG_TPU:'systolic array',ENG_NTT:'butterflies',ENG_CRYPTO:'crypto slot'};
const MODCOL={'u_mom.g_shared.u_ce':'#ffc145','u_mom.g_shared':'#e8a83a','u_mom':'#86a8ff','u_mom.u_sb':'#67cf8b',
  'u_mom.u_cal':'#d197f2','u_mom.u_feat':'#4fd3d9','u_regs':'#ff8a8a','u_spi':'#f08bd0','u_rst_sync':'#e3d35a'};
function state(el,html){if(el)el.innerHTML=html||''}
const LOADING='<div>Developing the mask: unpacking the layout of the hardened tile.<div class="bar"><i></i></div></div>';

// ---------- data -------------------------------------------------------
let DATA=null;
function data(){if(DATA)return DATA;DATA=(async()=>{
  if(!DM)throw new Error('nodata');
  if(typeof DecompressionStream==='undefined')throw new Error('nodecompress');
  const unpack=async id=>{const s=document.getElementById(id).textContent.trim();let bytes;
    try{bytes=new Uint8Array(await (await fetch('data:application/octet-stream;base64,'+s)).arrayBuffer())}
    catch(e){const b=atob(s);bytes=new Uint8Array(b.length);for(let i=0;i<b.length;i++)bytes[i]=b.charCodeAt(i)}
    return new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer()};
  const arrays=(buf,toc)=>{const o={};for(const [k,e] of Object.entries(toc)){
    if(e.type==='utf8'){o[k]=new TextDecoder().decode(new Uint8Array(buf,e.offset,e.count));continue}
    const T={H:Uint16Array,B:Uint8Array,I:Uint32Array}[e.type];const a=new T(buf,e.offset,e.count);
    if(e.delta)for(let i=1;i<a.length;i++)a[i]+=a[i-1];o[k]=a}return o};
  const L=arrays(await unpack('die-bin'),DM.bin.toc);
  const G=DG&&document.getElementById('diegl-bin').textContent.trim()?arrays(await unpack('diegl-bin'),DG.bin.toc):null;
  return prepare(L,G)})();return DATA}

function prepare(L,G){
  const u=DM.unit_um,ch=DM.cell_h_um,tu=DM.template_unit_um,n=L.cell_x.length;
  const W=DM.die_um[2]-DM.die_um[0],H=DM.die_um[3]-DM.die_um[1];
  const P={W,H,n,nets:L.net_names.split('\n'),netmod:L.net_module,mods:DM.modules,cellmac:L.cell_macro};
  P.cells=new Float32Array(n*4);P.cellcm=new Uint8Array(n*2);
  for(let i=0;i<n;i++){P.cells[i*4]=L.cell_x[i]*u;P.cells[i*4+1]=L.cell_y[i]*u;P.cells[i*4+2]=L.cell_w[i]*u;P.cells[i*4+3]=ch;
    P.cellcm[i*2]=L.cell_class[i];P.cellcm[i*2+1]=L.cell_module[i]}
  const rects=(x,y,w,h,net)=>{const k=x.length,r=new Float32Array(k*4);for(let i=0;i<k;i++){r[i*4]=x[i]*u;r[i*4+1]=y[i]*u;r[i*4+2]=w[i]*u;r[i*4+3]=h[i]*u}return {rect:r,net,k}};
  P.wires={};for(const l of ['met1','met2','met3','met4'])if(L[l+'_x'])P.wires[l]=rects(L[l+'_x'],L[l+'_y'],L[l+'_w'],L[l+'_h'],L[l+'_net']);
  P.vias={};for(const v of DM.vias){const c=v.cut;if(!L[c+'_x'])continue;const k=L[c+'_x'].length,s=v.size_um,r=new Float32Array(k*4);
    for(let i=0;i<k;i++){r[i*4]=L[c+'_x'][i]*u-s/2;r[i*4+1]=L[c+'_y'][i]*u-s/2;r[i*4+2]=s;r[i*4+3]=s}P.vias[c]={rect:r,net:L[c+'_net'],k}}
  // the power grid: rails on metal 1, straps on metal 4
  P.power={};const pl=L.power_layer;for(const li of [1,4]){const idx=[];for(let i=0;i<pl.length;i++)if(pl[i]===li)idx.push(i);
    const r=new Float32Array(idx.length*4);idx.forEach((j,k)=>{r[k*4]=L.power_x[j]*u;r[k*4+1]=L.power_y[j]*u;r[k*4+2]=L.power_w[j]*u;r[k*4+3]=L.power_h[j]*u});
    P.power[li]={rect:r,net:new Uint16Array(idx.length).fill(65535),k:idx.length}}
  // each cell type's own drawing, as triangles in cell coordinates
  const nm=DM.macros.length,toff=L.tpl_offset,tcnt=L.tpl_count;P.tplStart=new Int32Array(nm);P.tplCount=new Int32Array(nm);
  let nv=0;for(let m=0;m<nm;m++){P.tplStart[m]=nv;P.tplCount[m]=tcnt[m]*6;nv+=tcnt[m]*6}
  P.tpl=new Float32Array(nv*3);let q=0;
  for(let m=0;m<nm;m++)for(let k=toff[m];k<toff[m]+tcnt[m];k++){const x1=L.tpl_x1[k]*tu,y1=L.tpl_y1[k]*tu,x2=L.tpl_x2[k]*tu,y2=L.tpl_y2[k]*tu,ly=L.tpl_layer[k];
    for(const [a,b] of [[x1,y1],[x2,y1],[x2,y2],[x1,y1],[x2,y2],[x1,y2]]){P.tpl[q++]=a;P.tpl[q++]=b;P.tpl[q++]=ly}}
  // cells sorted by die tile, then type, so a close view draws only its tiles
  const TX=16,TY=12;P.TX=TX;P.TY=TY;const tile=new Uint16Array(n);
  for(let i=0;i<n;i++)tile[i]=Math.min(TY-1,Math.floor(P.cells[i*4+1]/H*TY))*TX+Math.min(TX-1,Math.floor(P.cells[i*4]/W*TX));
  const order=Array.from({length:n},(_,i)=>i).sort((a,b)=>tile[a]-tile[b]||L.cell_macro[a]-L.cell_macro[b]);
  P.inst=new Float32Array(n*4);P.runs=[...Array(TX*TY)].map(()=>[]);
  order.forEach((i,k)=>{P.inst[k*4]=P.cells[i*4];P.inst[k*4+1]=P.cells[i*4+1];P.inst[k*4+2]=P.cells[i*4+2];P.inst[k*4+3]=L.cell_orient[i];
    const t=tile[i],m=L.cell_macro[i],r=P.runs[t],last=r[r.length-1];if(last&&last[0]===m)last[2]++;else r.push([m,k,1])});
  // where each RTL block's cells are: median and spread, for labels and the story
  P.modcells={};for(let i=0;i<n;i++){const m=P.cellcm[i*2+1]&127;if(!m)continue;const name=DM.modules[m-1];
    (P.modcells[name]=P.modcells[name]||[]).push(i)}
  const pct=(a,p)=>a[Math.min(a.length-1,Math.max(0,Math.floor(p*(a.length-1))))];
  P.modstat={};for(const [k,idx] of Object.entries(P.modcells)){const xs=idx.map(i=>P.cells[i*4]+P.cells[i*4+2]/2).sort((a,b)=>a-b),ys=idx.map(i=>P.cells[i*4+1]+ch/2).sort((a,b)=>a-b);
    P.modstat[k]={n:idx.length,named:idx.filter(i=>!(P.cellcm[i*2+1]&128)).length,x:pct(xs,.5),y:pct(ys,.5),x0:pct(xs,.1),x1:pct(xs,.9),y0:pct(ys,.1),y1:pct(ys,.9)}}
  // the recording: the value of every net in every cycle of the window
  if(G){const nn=P.nets.length,c0=DG.cycles[0],c1=DG.cycles[1];P.c0=c0;P.c1=c1;P.snap=[];let cur=new Uint8Array(G.state0),e=0;
    P.snap.push(cur.slice());for(let c=0;c<c1-c0;c++){for(let j=0;j<G.per_cycle[c];j++,e++)cur[G.ev_net[e]]=G.ev_val[e];P.snap.push(cur.slice())}
    P.activity=G.activity;P.nn=nn}
  return P}

// ---------- WebGL --------------------------------------------------------
const VS_RECT=`#version 300 es
in vec2 corner;in vec4 rect;in uint net;
uniform vec2 uC;uniform float uS;uniform vec2 uView;uniform mat2 uR;uniform float uLift;uniform sampler2D uState;uniform float uMinPx;uniform int uLitPass;uniform int uPick;uniform int uFocus;uniform uint uMask;
out float vCov;out float vGlow;out float vFlash;out float vSel;out float vDim;
void main(){vec2 sz=rect.zw*uS;float g=0.0,fl=0.0;uint m=0u;
 if(net!=65535u){vec4 st=texelFetch(uState,ivec2(int(net)%128,int(net)/128),0);g=st.r;fl=st.b;m=uint(st.g*255.0+0.5);}
 float mp=uLitPass==1?max(uMinPx,1.0+0.8*fl):uMinPx;vec2 s2=max(sz,vec2(mp));
 vCov=min(1.0,(sz.x/s2.x)*(sz.y/s2.y));vGlow=g;vFlash=fl;vSel=(uPick>=0&&int(net)==uPick)?1.0:0.0;
 vDim=(uFocus==1&&((uMask>>(m&31u))&1u)==0u)?0.28:1.0;
 if(uLitPass==1&&g<0.02&&fl<0.02&&vSel<0.5){gl_Position=vec4(2.0,2.0,0.0,1.0);return;}
 vec2 w=rect.xy+rect.zw*0.5-uC+(corner-0.5)*s2/uS;vec2 c=(uR*w)*uS+vec2(0.0,uLift);gl_Position=vec4(c/(uView*0.5),0.0,1.0);}`;
const FS_RECT=`#version 300 es
precision highp float;precision highp int;in float vCov;in float vGlow;in float vFlash;in float vSel;in float vDim;
uniform vec4 uColor;uniform vec3 uLit;uniform vec3 uCore;uniform int uLitPass;uniform float uExp;out vec4 o;
void main(){if(uLitPass==1){float a=vSel>0.5?1.0:clamp(vGlow*0.34*vDim+vFlash*0.95,0.0,1.0)*mix(0.45,1.0,vCov);
   vec3 c=vSel>0.5?vec3(1.0):mix(uLit,uCore,vFlash);o=vec4(c*a,a)*uExp;return;}
 float a=uColor.a*vCov*vDim;vec3 c=uColor.rgb*(1.0+0.25*vGlow);o=vec4(c*a,a)*uExp;}`;
const VS_CELL=`#version 300 es
in vec2 corner;in vec4 rect;in uvec2 cm;
uniform vec2 uC;uniform float uS;uniform vec2 uView;uniform mat2 uR;uniform float uLift;uniform float uMinPx;uniform int uFocus;uniform uint uMask;uniform vec4 uClass[8];uniform vec4 uMod[16];
out vec4 vCol;
void main(){vec2 sz=rect.zw*uS;vec2 s2=max(sz,vec2(uMinPx));float cov=min(1.0,(sz.x/s2.x)*(sz.y/s2.y));
 uint m=cm.y&127u;vec4 col=uClass[int(cm.x)];
 if(uFocus==1){bool on=m>0u&&((uMask>>m)&1u)==1u;col=on?vec4(uMod[int(m)].rgb,(cm.y&128u)!=0u?0.55:0.9):vec4(col.rgb*0.6,col.a);}
 vCol=vec4(col.rgb*col.a*cov,col.a*cov);
 vec2 w=rect.xy+rect.zw*0.5-uC+(corner-0.5)*s2/uS;vec2 c=(uR*w)*uS+vec2(0.0,uLift);gl_Position=vec4(c/(uView*0.5),0.0,1.0);}`;
const FS_COL=`#version 300 es
precision highp float;precision highp int;in vec4 vCol;uniform float uExp;out vec4 o;void main(){o=vCol*uExp;}`;
const VS_TPL=`#version 300 es
in vec3 pos;in vec4 inst;
uniform vec2 uC;uniform float uS;uniform vec2 uView;uniform mat2 uR;uniform float uLift;uniform float uCellH;uniform vec4 uLayer[8];uniform int uOn;uniform float uFade;
out vec4 vCol;
void main(){int ly=int(pos.z+0.5);vec2 p=pos.xy;float w=inst.z,h=uCellH;int o=int(inst.w+0.5);
 if(o==1)p.y=h-p.y;else if(o==2){p.x=w-p.x;p.y=h-p.y;}else if(o==3)p.x=w-p.x;
 vec4 col=((uOn>>ly)&1)==1?uLayer[ly]:vec4(0.0);col.a*=uFade;vCol=vec4(col.rgb*col.a,col.a);
 vec2 c=(uR*(inst.xy+p-uC))*uS+vec2(0.0,uLift);gl_Position=vec4(c/(uView*0.5),0.0,1.0);}`;

function sh(gl,type,src){const s=gl.createShader(type);gl.shaderSource(s,src);gl.compileShader(s);
  if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw new Error('shader: '+gl.getShaderInfoLog(s));return s}
function prog(gl,vs,fs){const p=gl.createProgram();gl.attachShader(p,sh(gl,gl.VERTEX_SHADER,vs));gl.attachShader(p,sh(gl,gl.FRAGMENT_SHADER,fs));gl.linkProgram(p);
  if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw new Error('link: '+gl.getProgramInfoLog(p));
  const u={};const nu=gl.getProgramParameter(p,gl.ACTIVE_UNIFORMS);for(let i=0;i<nu;i++){const a=gl.getActiveUniform(p,i);const nmm=a.name.replace(/\[0\]$/,'');u[nmm]=gl.getUniformLocation(p,a.name)}
  return {p,u,a:n=>gl.getAttribLocation(p,n)}}

const LAYER_UI=[['cells','Cells','#3a3f4a'],['diff','Diffusion','diff'],['poly','Polysilicon','poly'],['li1','Local interconnect (li1)','li1'],
  ['met1','Metal 1','met1'],['met2','Metal 2','met2'],['met3','Metal 3','met3'],['met4','Metal 4','met4'],['vias','Vias','via'],['power','Power grid','power']];
const TPL_LAYERS=DM?DM.cell_layers:[];

class DieView{
  constructor(canvas,o){this.cv=canvas;canvas._die=this;this.o=o||{};this.cam={x:0,y:0,l:0,tilt:0,yaw:0};this.tgt={x:0,y:0,l:0,tilt:0,yaw:0};this.v={x:0,y:0,l:0,tilt:0,yaw:0};
    this.show={cells:1,diff:1,poly:1,li1:1,met1:1,met2:1,met3:1,met4:1,vias:1,power:1};this.focus=false;this.mask=0;this.pick=-1;
    this.cycle=null;this.raf=0;this.last=0;this.visible=true;this.listeners=[]}
  init(P){this.P=P;const gl=this.cv.getContext('webgl2',{antialias:true,premultipliedAlpha:true,alpha:false,preserveDrawingBuffer:false});
    if(!gl)throw new Error('nowebgl');this.gl=gl;
    this.pr=prog(gl,VS_RECT,FS_RECT);this.pc=prog(gl,VS_CELL,FS_COL);this.pt=prog(gl,VS_TPL,FS_COL);
    const quad=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,quad);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([0,0,1,0,0,1,1,1]),gl.STATIC_DRAW);this.quad=quad;
    const mk=(prg,rect,net,cm)=>{const vao=gl.createVertexArray();gl.bindVertexArray(vao);
      gl.bindBuffer(gl.ARRAY_BUFFER,quad);let a=prg.a('corner');gl.enableVertexAttribArray(a);gl.vertexAttribPointer(a,2,gl.FLOAT,false,0,0);
      const rb=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,rb);gl.bufferData(gl.ARRAY_BUFFER,rect,gl.STATIC_DRAW);a=prg.a('rect');gl.enableVertexAttribArray(a);gl.vertexAttribPointer(a,4,gl.FLOAT,false,0,0);gl.vertexAttribDivisor(a,1);
      if(net){const nb=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,nb);gl.bufferData(gl.ARRAY_BUFFER,net,gl.STATIC_DRAW);a=prg.a('net');gl.enableVertexAttribArray(a);gl.vertexAttribIPointer(a,1,gl.UNSIGNED_SHORT,0,0);gl.vertexAttribDivisor(a,1)}
      if(cm){const cb=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,cb);gl.bufferData(gl.ARRAY_BUFFER,cm,gl.STATIC_DRAW);a=prg.a('cm');gl.enableVertexAttribArray(a);gl.vertexAttribIPointer(a,2,gl.UNSIGNED_BYTE,0,0);gl.vertexAttribDivisor(a,1)}
      gl.bindVertexArray(null);return {vao,k:rect.length/4}};
    this.vCells=mk(this.pc,P.cells,null,P.cellcm);
    this.vW={};for(const [l,w] of Object.entries(P.wires))this.vW[l]=mk(this.pr,w.rect,w.net);
    this.vV={};for(const [c,w] of Object.entries(P.vias))this.vV[c]=mk(this.pr,w.rect,w.net);
    this.vP={};for(const [l,w] of Object.entries(P.power))this.vP[l]=mk(this.pr,w.rect,w.net);
    // templates
    const vao=gl.createVertexArray();gl.bindVertexArray(vao);const tb=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,tb);gl.bufferData(gl.ARRAY_BUFFER,P.tpl,gl.STATIC_DRAW);
    let a=this.pt.a('pos');gl.enableVertexAttribArray(a);gl.vertexAttribPointer(a,3,gl.FLOAT,false,0,0);
    const ib=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,ib);gl.bufferData(gl.ARRAY_BUFFER,P.inst,gl.STATIC_DRAW);this.instBuf=ib;this.instLoc=this.pt.a('inst');
    gl.enableVertexAttribArray(this.instLoc);gl.vertexAttribDivisor(this.instLoc,1);gl.bindVertexArray(null);this.vT=vao;
    // per-net state: R = glow, G = RTL block of the driving cell
    this.nn=P.nets.length;this.th=Math.ceil(this.nn/128);this.stbuf=new Uint8Array(128*this.th*4);for(let i=0;i<this.nn;i++)this.stbuf[i*4+1]=P.netmod[i]&127;
    this.glow=new Float32Array(this.nn);this.target=new Float32Array(this.nn);this.flash=new Float32Array(this.nn);this.exposure=1;this.region=null;
    this.tex=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,this.tex);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,128,this.th,0,gl.RGBA,gl.UNSIGNED_BYTE,this.stbuf);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
    this.cv.addEventListener('webglcontextlost',e=>{e.preventDefault();this.lost=true;this.o.onError&&this.o.onError('lost')});
    this.fit(true);this.resize();new ResizeObserver(()=>{this.resize();this.kick()}).observe(this.cv);
    if(this.o.interactive)this.bind();this.kick();return this}
  resize(){const dpr=Math.min(2,devicePixelRatio||1);const w=Math.max(1,Math.round(this.cv.clientWidth*dpr)),h=Math.max(1,Math.round(this.cv.clientHeight*dpr));
    if(this.cv.width!==w||this.cv.height!==h){this.cv.width=w;this.cv.height=h}this.dpr=dpr}
  fitScale(w,h){const cw=this.cv.clientWidth||800,chh=this.cv.clientHeight||600;return Math.log(Math.min(cw/w,chh/h))}
  fit(now){const P=this.P;this.frame(-P.W*0.03,-P.H*0.03,P.W*1.03,P.H*1.03,now,null)}
  setTarget(x,y,l,now){this.tgt.x=x;this.tgt.y=y;this.tgt.l=l;if(now||RM.matches){this.cam.x=x;this.cam.y=y;this.cam.l=l;this.v.x=this.v.y=this.v.l=0}this.kick()}
  // fit a layout box into a part of the canvas (CSS px: {x,y,w,h}), or all of it
  frame(x0,y0,x1,y1,now,rg){const cw=this.cv.clientWidth||800,chh=this.cv.clientHeight||600;const r=rg||{x:0,y:0,w:cw,h:chh};
    const l=Math.log(Math.min(r.w/((x1-x0)*1.04),r.h/((y1-y0)*1.04))),s=Math.exp(l);
    this.setTarget((x0+x1)/2-(r.x+r.w/2-cw/2)/s,(y0+y1)/2+(r.y+r.h/2-chh/2)/s,l,now)}
  setCycle(c){if(!this.P.snap)return;c=Math.max(this.P.c0,Math.min(this.P.c1,Math.round(c)));if(c===this.cycle)return;
    const s=this.P.snap[c-this.P.c0];const first=this.cycle==null;this.cycle=c;
    for(let i=0;i<this.nn;i++){const v=s[i]===1?1:0;if(!first&&v!==this.target[i]&&!RM.matches)this.flash[i]=1;this.target[i]=v}
    if(RM.matches||first)this.glow.set(this.target);this.kick();this.o.onCycle&&this.o.onCycle(c)}
  kick(){if(!this.raf&&this.gl&&!this.lost)this.raf=requestAnimationFrame(t=>this.tick(t))}
  tick(t){this.raf=0;const dt=this.last?Math.min(0.25,(t-this.last)/1000):0.016;this.last=t;let moving=false;
    // camera: a critically damped spring on centre and log-scale
    // (in steps of at most 1/60 s, so a slow frame does not slow the camera or make it unstable)
    if(!RM.matches){const k=this.o.stiff||140,c=2*Math.sqrt(k),n=Math.ceil(dt/0.0167),h=dt/n;for(const a of ['x','y','l','tilt','yaw']){for(let q=0;q<n;q++){const d0=this.tgt[a]-this.cam[a];this.v[a]+=(k*d0-c*this.v[a])*h;this.cam[a]+=this.v[a]*h}const d=this.tgt[a]-this.cam[a];
        const eps=(a==='l'||a==='tilt'||a==='yaw')?1e-4:0.002/Math.exp(this.cam.l);if(Math.abs(d)>eps||Math.abs(this.v[a])>eps)moving=true;else{this.cam[a]=this.tgt[a];this.v[a]=0}}}
    else{Object.assign(this.cam,this.tgt)}
    // nets: rise fast, fall with an afterglow
    // a net that switches flashes and fades (the flash is the news, the level is the state)
    let glowing=false;const up=1-Math.exp(-dt/0.045),dn=1-Math.exp(-dt/0.26),fd=Math.exp(-dt/0.42);
    for(let i=0;i<this.nn;i++){const g=this.glow[i],tg=this.target[i];if(g!==tg){const ng=g+(tg-g)*(tg>g?up:dn);this.glow[i]=Math.abs(ng-tg)<0.004?tg:ng;glowing=true}
      let f=this.flash[i];if(f>0){f=f*fd;if(f<0.01)f=0;this.flash[i]=f;glowing=true}
      this.stbuf[i*4]=Math.round(this.glow[i]*255);this.stbuf[i*4+2]=Math.round(f*255)}
    this.draw();this.o.onFrame&&this.o.onFrame(this);
    if((moving||glowing||this.anim)&&this.visible)this.kick()}
  draw(){const gl=this.gl,P=this.P;if(!gl||this.lost)return;this.resize();const W=this.cv.width,H=this.cv.height,s=Math.exp(this.cam.l)*this.dpr;
    gl.viewport(0,0,W,H);const bg=rgb(PAL.substrate);gl.clearColor(bg[0],bg[1],bg[2],1);gl.clear(gl.COLOR_BUFFER_BIT);
    gl.enable(gl.BLEND);gl.blendFunc(gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
    gl.bindTexture(gl.TEXTURE_2D,this.tex);gl.texSubImage2D(gl.TEXTURE_2D,0,0,0,128,this.th,gl.RGBA,gl.UNSIGNED_BYTE,this.stbuf);
    const pxum=Math.exp(this.cam.l);const view=[W,H];
    // the exploded view: plan turned by yaw, squashed by the pitch, each layer lifted
    const tl=Math.max(0,Math.min(1,this.cam.tilt)),cy0=Math.cos(this.cam.yaw*tl),sy0=Math.sin(this.cam.yaw*tl),sq=1-0.52*tl;
    const R=new Float32Array([cy0,sy0*sq,-sy0,cy0*sq]);const gap=tl*H*0.105;this._R=R;this._gap=gap;
    const lift=(pp,k)=>{gl.uniformMatrix2fv(pp.u.uR,false,R);gl.uniform1f(pp.u.uLift,(k-1.6)*gap)};
    const common=(pp)=>{gl.useProgram(pp.p);gl.uniform2f(pp.u.uC,this.cam.x,this.cam.y);gl.uniform1f(pp.u.uS,s);gl.uniform2f(pp.u.uView,view[0],view[1]);
      if(pp.u.uMinPx)gl.uniform1f(pp.u.uMinPx,1.0*this.dpr*0.75);if(pp.u.uFocus)gl.uniform1i(pp.u.uFocus,this.focus?1:0);if(pp.u.uMask)gl.uniform1ui(pp.u.uMask,this.mask>>>0);if(pp.u.uExp)gl.uniform1f(pp.u.uExp,this.exposure)};
    // cells
    if(this.show.cells){const pc=this.pc;common(pc);const cls=DM.classes.map(k=>{const c=rgb(k==='fill'?PAL.fill:PAL.cell);return [c[0],c[1],c[2],1]});
      const cl=new Float32Array(32);cls.forEach((c,i)=>cl.set(c,i*4));gl.uniform4fv(pc.u.uClass,cl);
      const md=new Float32Array(64);DM.modules.forEach((m,i)=>{const c=rgb(MODCOL[m]||'#cccccc');md.set([c[0],c[1],c[2],1],(i+1)*4)});gl.uniform4fv(pc.u.uMod,md);
      lift(pc,0);gl.bindVertexArray(this.vCells.vao);gl.drawArraysInstanced(gl.TRIANGLE_STRIP,0,4,this.vCells.k)}
    // inside the cells, once there is room to see them
    const tplFade=Math.max(0,Math.min(1,(pxum-10)/8));
    if(tplFade>0){const pt=this.pt;gl.useProgram(pt.p);gl.uniform2f(pt.u.uC,this.cam.x,this.cam.y);gl.uniform1f(pt.u.uS,s);gl.uniform2f(pt.u.uView,W,H);gl.uniform1f(pt.u.uCellH,DM.cell_h_um);gl.uniform1f(pt.u.uFade,tplFade);gl.uniform1f(pt.u.uExp,this.exposure);lift(pt,0);
      const lc=new Float32Array(32);let on=0;TPL_LAYERS.forEach((nm,i)=>{const key=nm==='tap'?'diff':(nm==='licon'||nm==='mcon')?'li1':nm==='nwell'?'diff':nm;
        const col=rgb(PAL[nm]||'#888888');const al={nwell:.22,diff:.85,tap:.7,poly:.9,licon:.9,li1:.7,mcon:.9,met1:.75}[nm]||.8;lc.set([col[0],col[1],col[2],al],i*4);if(this.show[key])on|=1<<i});
      gl.uniform4fv(pt.u.uLayer,lc);gl.uniform1i(pt.u.uOn,on);gl.bindVertexArray(this.vT);gl.bindBuffer(gl.ARRAY_BUFFER,this.instBuf);
      const hw=W/2/s,hh=H/2/s,x0=this.cam.x-hw-30,x1=this.cam.x+hw,y0=this.cam.y-hh-3,y1=this.cam.y+hh;
      const tx0=Math.max(0,Math.floor(x0/P.W*P.TX)),tx1=Math.min(P.TX-1,Math.floor(x1/P.W*P.TX)),ty0=Math.max(0,Math.floor(y0/P.H*P.TY)),ty1=Math.min(P.TY-1,Math.floor(y1/P.H*P.TY));
      for(let ty=ty0;ty<=ty1;ty++)for(let tx=tx0;tx<=tx1;tx++)for(const [m,st,cnt] of P.runs[ty*P.TX+tx]){if(!P.tplCount[m])continue;
        gl.vertexAttribPointer(this.instLoc,4,gl.FLOAT,false,0,st*16);gl.drawArraysInstanced(gl.TRIANGLES,P.tplStart[m],P.tplCount[m],cnt)}}
    // wires, vias and power, bottom to top
    const pr=this.pr;common(pr);gl.uniform1i(pr.u.uPick,this.pick);gl.uniform1i(pr.u.uLitPass,0);
    const lit=rgb(PAL.lit),core=rgb(PAL.lit_core);gl.uniform3f(pr.u.uLit,lit[0],lit[1],lit[2]);gl.uniform3f(pr.u.uCore,core[0],core[1],core[2]);
    const drawSet=(v,col,a,k)=>{if(!v)return;lift(pr,k||0);const c=rgb(col);gl.uniform4f(pr.u.uColor,c[0],c[1],c[2],a);gl.bindVertexArray(v.vao);gl.drawArraysInstanced(gl.TRIANGLE_STRIP,0,4,v.k)};
    const viaA=Math.max(0,Math.min(1,(pxum-1.5)/4));
    // close in, metal thins out so the cells' own layers show through
    const mA=1-0.55*Math.max(0,Math.min(1,(pxum-14)/30));
    if(this.show.power)drawSet(this.vP[1],PAL.power,.75,1);
    if(this.show.met1)drawSet(this.vW.met1,PAL.met1,.62*mA,1);
    if(this.show.vias&&viaA>0){drawSet(this.vV.mcon,PAL.mcon,.7*viaA,1);drawSet(this.vV.via,PAL.via,.8*viaA,2)}
    if(this.show.met2)drawSet(this.vW.met2,PAL.met2,.62*mA,2);
    if(this.show.vias&&viaA>0)drawSet(this.vV.via2,PAL.via2,.8*viaA,3);
    if(this.show.met3)drawSet(this.vW.met3,PAL.met3,.7*mA,3);
    if(this.show.vias&&viaA>0)drawSet(this.vV.via3,PAL.via3,.8*viaA,4);
    if(this.show.met4)drawSet(this.vW.met4,PAL.met4,.72*mA,4);
    if(this.show.power)drawSet(this.vP[4],PAL.power,.55,4);
    // the lit pass: every net that is high, on top, so activity reads from afar
    gl.uniform1i(pr.u.uLitPass,1);gl.blendFunc(gl.ONE,gl.ONE);
    ['met1','met2','met3','met4'].forEach((l,k)=>{if(this.show[l])drawSet(this.vW[l],'#000000',1,k+1)});
    gl.blendFunc(gl.ONE,gl.ONE_MINUS_SRC_ALPHA);gl.bindVertexArray(null)}
  // screen <-> layout
  toWorld(px,py){const r=this.cv.getBoundingClientRect(),s=Math.exp(this.cam.l);return [this.cam.x+(px-r.left-r.width/2)/s,this.cam.y-(py-r.top-r.height/2)/s]}
  toScreen(x,y,k){const r=this.cv.getBoundingClientRect(),s=Math.exp(this.cam.l),R=this._R||[1,0,0,1];const dx=x-this.cam.x,dy=y-this.cam.y;
    const px=(R[0]*dx+R[2]*dy)*s,py=(R[1]*dx+R[3]*dy)*s+((k||0)-1.6)*(this._gap||0)/this.dpr;return [r.width/2+px,r.height/2-py]}
  zoomAt(px,py,f){const [wx,wy]=this.toWorld(px,py);const r=this.cv.getBoundingClientRect();const nl=Math.max(this.fitScale(this.P.W*3,this.P.H*3),Math.min(Math.log(400),this.tgt.l+Math.log(f)));
    const s=Math.exp(nl);this.tgt.l=nl;this.tgt.x=wx-(px-r.left-r.width/2)/s;this.tgt.y=wy+(py-r.top-r.height/2)/s;if(RM.matches){Object.assign(this.cam,this.tgt)}this.kick()}
  pan(dx,dy){const s=Math.exp(this.tgt.l);this.tgt.x-=dx/s;this.tgt.y+=dy/s;this.cam.x-=dx/Math.exp(this.cam.l);this.cam.y+=dy/Math.exp(this.cam.l);this.kick()}
  bind(){const cv=this.cv;const pts=new Map();let moved=0,lastT=0,vx=0,vy=0;
    cv.addEventListener('wheel',e=>{e.preventDefault();const f=Math.exp(-e.deltaY*(e.deltaMode===1?0.05:0.0018));this.zoomAt(e.clientX,e.clientY,f)},{passive:false});
    cv.addEventListener('pointerdown',e=>{cv.setPointerCapture(e.pointerId);pts.set(e.pointerId,{x:e.clientX,y:e.clientY});moved=0;vx=vy=0;lastT=performance.now()});
    cv.addEventListener('pointermove',e=>{const r=this.cv.getBoundingClientRect();const [wx,wy]=this.toWorld(e.clientX,e.clientY);this.o.onHover&&this.o.onHover(wx,wy);
      const p=pts.get(e.pointerId);if(!p)return;
      if(pts.size===1&&this.tgt.tilt>0.5){const dx=e.clientX-p.x;moved+=Math.abs(dx)+Math.abs(e.clientY-p.y);this.tgt.yaw+=dx*0.006;p.x=e.clientX;p.y=e.clientY;this.kick();return}
      if(pts.size===1){const dx=e.clientX-p.x,dy=e.clientY-p.y;moved+=Math.abs(dx)+Math.abs(dy);this.pan(dx,dy);const t=performance.now(),d=Math.max(1,t-lastT);vx=dx/d;vy=dy/d;lastT=t}
      else if(pts.size===2){const [a,b]=[...pts.values()];const d0=Math.hypot(a.x-b.x,a.y-b.y);p.x=e.clientX;p.y=e.clientY;const [a2,b2]=[...pts.values()];
        const d1=Math.hypot(a2.x-b2.x,a2.y-b2.y);if(d0>0)this.zoomAt((a2.x+b2.x)/2,(a2.y+b2.y)/2,d1/d0);moved+=10;return}
      p.x=e.clientX;p.y=e.clientY});
    const up=e=>{const was=pts.has(e.pointerId);pts.delete(e.pointerId);if(!was)return;
      if(moved<5&&e.type==='pointerup'&&this.cam.tilt<0.05){const [wx,wy]=this.toWorld(e.clientX,e.clientY);this.o.onPick&&this.o.onPick(this.pickAt(wx,wy,6/Math.exp(this.cam.l)))}
      else if(!RM.matches&&pts.size===0&&performance.now()-lastT<80){this.pan(vx*140,vy*140)}};   // a flick keeps going a little
    cv.addEventListener('pointerup',up);cv.addEventListener('pointercancel',up);
    cv.addEventListener('dblclick',e=>{e.preventDefault();this.zoomAt(e.clientX,e.clientY,2.5)});
    cv.addEventListener('keydown',e=>{const r=cv.getBoundingClientRect(),cx=r.left+r.width/2,cy=r.top+r.height/2;const st=r.width*0.12;
      const k={ArrowLeft:()=>this.pan(st,0),ArrowRight:()=>this.pan(-st,0),ArrowUp:()=>this.pan(0,st),ArrowDown:()=>this.pan(0,-st),
        '+':()=>this.zoomAt(cx,cy,1.6),'=':()=>this.zoomAt(cx,cy,1.6),'-':()=>this.zoomAt(cx,cy,1/1.6),'_':()=>this.zoomAt(cx,cy,1/1.6),'0':()=>this.fit()}[e.key];
      if(k){e.preventDefault();k()}})}
  // the net under a point: the topmost visible wire or via within tol
  pickAt(x,y,tol){const P=this.P;if(!this.grid){const G=8,nx=Math.ceil(P.W/G),ny=Math.ceil(P.H/G),cells=new Map();
      const add=(layer,set)=>{for(let i=0;i<set.k;i++){const r=set.rect;const a=Math.floor(r[i*4]/G),b=Math.floor((r[i*4]+r[i*4+2])/G),c=Math.floor(r[i*4+1]/G),d=Math.floor((r[i*4+1]+r[i*4+3])/G);
        for(let gx=a;gx<=b;gx++)for(let gy=c;gy<=d;gy++){const key=gy*nx+gx;let l=cells.get(key);if(!l)cells.set(key,l=[]);l.push(layer,i)}}};
      this.order=['met4','met3','met2','met1'];this.order.forEach((l,j)=>P.wires[l]&&add(j,P.wires[l]));this.grid={G,nx,cells}}
    const {G,nx,cells}=this.grid;let best=null,bl=99,bd=1e9;
    for(let gx=Math.floor((x-tol)/G);gx<=Math.floor((x+tol)/G);gx++)for(let gy=Math.floor((y-tol)/G);gy<=Math.floor((y+tol)/G);gy++){const l=cells.get(gy*nx+gx);if(!l)continue;
      for(let k=0;k<l.length;k+=2){const L=this.order[l[k]];if(!this.show[L])continue;const r=P.wires[L].rect,i=l[k+1];
        const dx=Math.max(r[i*4]-x,0,x-(r[i*4]+r[i*4+2])),dy=Math.max(r[i*4+1]-y,0,y-(r[i*4+1]+r[i*4+3]));const d=Math.hypot(dx,dy);
        if(d<=tol&&(l[k]<bl||(l[k]===bl&&d<bd))){best={net:P.wires[L].net[i],layer:L};bl=l[k];bd=d}}}
    return best}
  netBox(net){const P=this.P;let x0=1e9,y0=1e9,x1=-1e9,y1=-1e9,n=0;for(const w of Object.values(P.wires))for(let i=0;i<w.k;i++)if(w.net[i]===net){const r=w.rect;
      x0=Math.min(x0,r[i*4]);y0=Math.min(y0,r[i*4+1]);x1=Math.max(x1,r[i*4]+r[i*4+2]);y1=Math.max(y1,r[i*4+1]+r[i*4+3]);n++}
    return n?[x0,y0,x1,y1,n]:null}
}

// ---------- shared pieces of the overlay -------------------------------
function scalebar(el,view){if(!el)return;const s=Math.exp(view.cam.l);const want=110/s;const p=Math.pow(10,Math.floor(Math.log10(want)));
  const v=[1,2,5,10].map(m=>m*p).filter(x=>x<=want).pop()||p;el.querySelector('span').style.width=(v*s).toFixed(1)+'px';
  el.querySelector('b').textContent=v>=1?`${v} µm`:`${Math.round(v*1000)} nm`;el.querySelector('b').style.fontWeight='400'}
function labels(el,view,on,maxX){if(!el)return;if(!on){el.innerHTML='';return}const P=view.P;
  if(!el.children.length)el.innerHTML=D.dispatch.filter(m=>P.modstat[m]).map(m=>`<i style="--c:${MODCOL[m]}" data-m="${m}">${D.modname[m]||m}</i>`).join('');
  [...el.children].forEach(i=>{const st=P.modstat[i.dataset.m];const [x,y]=view.toScreen(st.x,st.y);i.style.left=x+'px';i.style.top=y+'px';
    i.style.opacity=maxX&&x+i.offsetWidth/2>maxX?0:1})}
const mix2=(a,b,t)=>a+(b-a)*t;
function maskOf(names){let m=0;names.forEach(n=>{const i=DM.modules.indexOf(n);if(i>=0)m|=1<<(i+1)});return m}
function failMsg(e){const why={nowebgl:'this browser has WebGL 2 turned off or unavailable',nodecompress:'this browser cannot unpack compressed data (DecompressionStream)',
  nodata:'no routed layout was extracted when this page was built',lost:'the graphics context was lost'}[e&&e.message||e]||('an error: '+(e&&e.message||e));
  return `<div>The interactive layout cannot be drawn here: ${why}. The still picture is the same layout, rendered by Tiny Tapeout's own tool.</div>`}
function fallback(stageEl,stateEl,e){stageEl.closest('.story,.explorer').classList.remove('js-die');state(stateEl,failMsg(e))}

// ---------- the opening story ------------------------------------------
async function story(){const root=$('#story'),cv=$('#die-hero');if(!root||!cv)return;const stEl=$('#hero-state');
  const steps=$$('#story .step');steps.forEach(s=>s.classList.add('armed'));
  const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting)e.target.classList.add('lit')}),{threshold:.25});steps.forEach(s=>io.observe(s));
  state(stEl,LOADING);let P,view;
  try{P=await data();root.classList.add('js-die');view=new DieView(cv,{stiff:90}).init(P)}catch(e){fallback(cv,stEl,e);return}
  state(stEl,'');
  // keyframes, from where the cells really are
  const K=[];const full=[0,0,P.W,P.H];K.push(full);
  const disp=D.dispatch.filter(m=>P.modstat[m]).map(m=>P.modstat[m]);
  const box=a=>[Math.min(...a.map(s=>s.x0)),Math.min(...a.map(s=>s.y0)),Math.max(...a.map(s=>s.x1)),Math.max(...a.map(s=>s.y1))];
  K.push(disp.length?box(disp):full);
  const ce=P.modstat['u_mom.g_shared.u_ce']||disp[0];const cw=Math.min(P.W/3,150),chh=cw*0.7;
  const kc=ce?[ce.x-cw/2,ce.y-chh/2,ce.x+cw/2,ce.y+chh/2]:full;K.push(kc);
  // a named register of the cost engine, nearest the middle of that view
  let flop=-1,fd=1e18;const fi=DM.classes.indexOf('flop'),ci=DM.modules.indexOf('u_mom.g_shared.u_ce')+1;
  for(let i=0;i<P.n;i++)if(P.cellcm[i*2]===fi&&P.cellcm[i*2+1]===ci){const d=(P.cells[i*4]-ce.x)**2+(P.cells[i*4+1]-ce.y)**2;if(d<fd){fd=d;flop=i}}
  if(flop<0)for(let i=0;i<P.n;i++)if(P.cellcm[i*2]===fi){flop=i;break}
  const fx=P.cells[flop*4]+P.cells[flop*4+2]/2,fy=P.cells[flop*4+1]+DM.cell_h_um/2;K.push([fx-9,fy-6,fx+9,fy+6]);K.push([-P.W*0.42,-P.H*0.62,P.W*1.42,P.H*1.62]);K.push(full);
  const sc=$('#story-cell');
  const ev=(D.traces[DG&&DG.trace]||{events:[]}).events;const go=(ev.find(e=>e.k==='go'&&P.c0<=e.c&&e.c<=P.c1)||{c:P.c0}).c;
  const sel=ev.find(e=>e.k==='select'&&P.c0<=e.c&&e.c<=P.c1);const cEnd=sel?sel.c:P.c1;
  const rows=$$('#story table.mini tr');const cyc=$('#story-cycle');const hud=$('#hero-hud');
  view.o.onCycle=c=>{rows.forEach(r=>{r.classList.toggle('on',+r.dataset.c<=c)});if(sel)rows.forEach(r=>{const l=ev.find(e=>e.k==='lane'&&e.c===+r.dataset.c);r.classList.toggle('win',c>=sel.c&&l&&l.eng===sel.eng)});
    if(cyc)cyc.textContent=`Cycle ${c.toLocaleString()} of the gate-level recording`+((ev.find(e=>e.c===c&&e.k!=='stall')||{}).k?`: ${ev.filter(e=>e.c===c&&e.k!=='stall').map(e=>({go:'GO',desc:'descriptor taken',feat:'features ready',lane:`row ${e.eng} costed`,select:'select',tag:`tag ${e.tag} handed out`,spi:'SPI frame'}[e.k]||e.k)).join(', ')}`:'');
    hud.innerHTML=`<span>${DG?DG.label:''}</span><span>cycle <b>${c.toLocaleString()}</b></span>`};
  let f=0,loopT=0,labMax=0;const ease=t=>t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;
  function place(){const vh=innerHeight,centre=vh*0.55;const mids=steps.map(s=>{const r=s.getBoundingClientRect();return r.top+r.height/2});
    // story position: 0 until the first step reaches the middle, then i+t between step centres
    let p=0;if(centre>=mids[0]){p=steps.length-1;for(let i=0;i<mids.length-1;i++)if(centre<mids[i+1]){p=i+(centre-mids[i])/(mids[i+1]-mids[i]);break}}
    const p0=Math.min(1,Math.max(0,(centre-(mids[0]-vh))/vh)),e0=RM.matches?Math.round(p0):ease(p0);
    f=p;const i=Math.min(K.length-2,Math.floor(f)),t=RM.matches?Math.round(f-i):ease(Math.min(1,f-i));
    const a=K[i],b=K[i+1],wa=a[2]-a[0],wb=b[2]-b[0],w=Math.exp(Math.log(wa)+(Math.log(wb)-Math.log(wa))*t);
    const h=w*((a[3]-a[1])/wa+((b[3]-b[1])/wb-(a[3]-a[1])/wa)*t),mix=(p,q)=>p+(q-p)*t;
    const cx=mix((a[0]+a[2])/2,(b[0]+b[2])/2),cy=mix((a[1]+a[3])/2,(b[1]+b[3])/2);
    // where on the stage the die sits: beside the title first, then beside the step cards
    const cw=cv.clientWidth,chh=cv.clientHeight,wide=cw>=760,card=steps[0].querySelector('.stepcard').getBoundingClientRect();
    const rIntro=wide?{x:cw*0.47,y:36,w:cw*0.51,h:chh-72}:{x:16,y:24,w:cw-32,h:chh*0.46};
    const rStep=wide?{x:36,y:36,w:Math.max(200,card.left-cv.getBoundingClientRect().left-72),h:chh-72}:{x:16,y:20,w:cw-32,h:Math.max(160,chh-card.height-56)};
    const rg={x:mix2(rIntro.x,rStep.x,e0),y:mix2(rIntro.y,rStep.y,e0),w:mix2(rIntro.w,rStep.w,e0),h:mix2(rIntro.h,rStep.h,e0)};
    view.exposure=0.5+0.5*e0;view.frame(cx-w/2,cy-h/2,cx+w/2,cy+h/2,false,rg);
    // step 5 peels the mask apart: tilt rises and falls around it, and the stack turns as you scroll
    const tb=Math.max(0,Math.min(1,1-Math.abs(f-4)/0.75));view.tgt.tilt=RM.matches?(Math.abs(f-4)<0.5?1:0):tb*tb*(3-2*tb);
    view.tgt.yaw=RM.matches?-0.5:-0.9+(f-3.3)*0.75;if(RM.matches)Object.assign(view.cam,view.tgt);
    // which cells are coloured: the dispatch unit from step 2 to step 4
    const foc=f>0.5&&f<2.55;view.focus=foc;view.mask=maskOf(D.dispatch);labMax=wide?card.left-cv.getBoundingClientRect().left-16:0;
    labels($('#hero-labels'),view,f>0.7&&f<1.5,labMax);root.dataset.f=f.toFixed(2);
    // the cycle: looping before step 3, scrubbed by scroll through it, then held at the select
    if(P.snap){if(f<1.55){view.anim=!RM.matches;if(RM.matches)view.setCycle(cEnd)}else{view.anim=false;const tt=Math.min(1,Math.max(0,(f-1.55)/0.9));view.setCycle(go+(cEnd-go)*tt)}}
    view.kick()}
  const lay=$('#hero-layers');const LN=[['cells and their transistors',P.n],['metal 1',DM.counts.met1],['metal 2',DM.counts.met2],['metal 3',DM.counts.met3],['metal 4',DM.counts.met4]];
  if(lay)lay.innerHTML=LN.map(([a,b],k)=>`<i data-k="${k}"><b>${a}</b> ${b.toLocaleString()}${k?' rectangles':' cells'}</i>`).join('');
  const tg=$('#hero-target');if(tg)tg.dataset.name=DM.macros[P.cellmac[flop]].replace('sky130_fd_sc_hd__','');
  view.o.onFrame=v=>{scalebar($('#hero-scale'),v);
    if(lay){const on=v.cam.tilt>0.6;lay.classList.toggle('on',on);if(on)[...lay.children].forEach(i=>{const k=+i.dataset.k;const [x,y]=v.toScreen(P.W,P.H*0.5,k);i.style.left=(x+18)+'px';i.style.top=y+'px'})}
    if(tg){const on=f>2.7&&f<3.45;tg.classList.toggle('on',on);if(on){const [x0,y1]=v.toScreen(P.cells[flop*4],P.cells[flop*4+1]),[x1,y0]=v.toScreen(P.cells[flop*4]+P.cells[flop*4+2],P.cells[flop*4+1]+DM.cell_h_um);
      tg.style.left=(x0-6)+'px';tg.style.top=(y0-6)+'px';tg.style.width=(x1-x0+12)+'px';tg.style.height=(y1-y0+12)+'px'}}
if(v.anim&&P.snap){const now=performance.now();if(now-loopT>420){loopT=now;const c=v.cycle==null||v.cycle>=P.c1?P.c0:v.cycle+1;v.setCycle(c)}}
    labels($('#hero-labels'),v,f>0.7&&f<1.5,labMax)};
  if(P.snap)view.setCycle(P.c0);
  addEventListener('scroll',place,{passive:true});addEventListener('resize',place);
  new IntersectionObserver(es=>{view.visible=es[0].isIntersecting;if(view.visible)view.kick()}).observe(root);
  place();Object.assign(view.cam,view.tgt);view.kick();
  // name the register the story lands on
  if(sc)sc.textContent=`The cell in the middle is a ${DM.macros[P.cellmac[flop]].replace('sky130_fd_sc_hd__','')}, a flip-flop that holds one bit of the cost engine.`;
}

// ---------- the explorer ------------------------------------------------
let EX=null;
async function explorer(){if(EX)return;const cv=$('#die-ex');if(!cv)return;EX=1;const root=$('#explorer'),stEl=$('#ex-state');state(stEl,LOADING);let P,view;
  try{P=await data();root.classList.add('js-die');view=new DieView(cv,{interactive:true,stiff:170}).init(P)}catch(e){fallback(cv,stEl,e);return}
  state(stEl,'');EX=view;
  // layer switches
  $('#ex-layers').innerHTML=LAYER_UI.map(([k,lab,c])=>`<label><input type="checkbox" data-l="${k}" checked><i style="--c:${PAL[c]||c}"></i>${lab}</label>`).join('');
  $$('#ex-layers input').forEach(i=>i.onchange=()=>{view.show[i.dataset.l]=i.checked?1:0;view.kick()});
  // the dispatch unit
  const mods=Object.entries(P.modstat).sort((a,b)=>b[1].n-a[1].n);
  $('#ex-mods').innerHTML=mods.map(([m,s])=>`<li><i style="--c:${MODCOL[m]||'#ccc'}"></i>${D.modname[m]||m}<span class="num">${s.n.toLocaleString()}</span></li>`).join('')+
    `<li class="muted">Cells per RTL block, named and inferred.</li>`;
  const foc=$('#ex-focus');foc.onchange=()=>{view.focus=foc.checked;view.mask=maskOf(Object.keys(P.modstat));view.kick()};
  // the recording
  const sl=$('#ex-cycle'),clk=$('#ex-clock'),cap=$('#ex-cap'),play=$('#ex-play');const ev=(D.traces[DG&&DG.trace]||{events:[]}).events;
  const words=e=>({go:'GO: the staged descriptor goes to the scheduler',desc:`the scheduler takes the descriptor (${e.op&&e.op.replace('OPC_','')} ${e.m}×${e.n}×${e.kk})`,
    feat:'features ready',lane:e.capable?`the cost engine writes row ${e.eng} (${ENG[e.name]||e.name}): cost ${e.cost}`:`row ${e.eng} (${ENG[e.name]||e.name}) refused: cannot run this job`,
    select:`select: ${ENG[(e.rows||[]).find(r=>r.chosen)?.name]||'?'} wins by ${e.margin}`,tag:`tag ${e.tag} handed out`,stall:'the scheduler holds off new work'}[e.k]||e.k);
  if(P.snap){sl.min=P.c0;sl.max=P.c1;sl.value=P.c0;view.o.onCycle=c=>{sl.value=c;clk.textContent=c.toLocaleString();cap.setAttribute('aria-live',view.playing?'off':'polite');
      const here=ev.filter(e=>e.c===c);cap.textContent=`Cycle ${c.toLocaleString()}: `+(here.length?here.map(words).join('; ')+'.':'no scheduler event this cycle; the lit wires are the nets that are high.')};
    view.setCycle(sel0());sl.oninput=()=>{stopPlay();view.setCycle(+sl.value)};
    $('#ex-prov').textContent=`${DG.label} · ${DG.result} · ${DG.test} on the hardened netlist ${DG.netlist_sha256.slice(0,12)} · cycles ${P.c0.toLocaleString()} to ${P.c1.toLocaleString()} of ${DG.clock_ns} ns · every net sampled just before the next rising edge · ${DG.pins_match_rtl} · ${DG.command}`}
  else{sl.disabled=true;play.disabled=true;cap.textContent='No gate-level recording was made for this layout, so no wire is lit.'}
  function sel0(){const s=ev.find(e=>e.k==='select'&&P.c0<=e.c&&e.c<=P.c1);return s?s.c:P.c0}
  let timer=null;function stopPlay(){view.playing=false;if(timer){clearInterval(timer);timer=null}play.setAttribute('aria-pressed','false');play.setAttribute('aria-label','Play');play.innerHTML='<svg aria-hidden="true"><use href="#i-play"/></svg>'}
  play.onclick=()=>{if(timer){stopPlay();return}view.playing=true;play.setAttribute('aria-pressed','true');play.setAttribute('aria-label','Pause');play.innerHTML='<svg aria-hidden="true"><use href="#i-pause"/></svg>';
    timer=setInterval(()=>{view.setCycle(view.cycle>=P.c1?P.c0:view.cycle+1)},RM.matches?1200:520)};
  // nets
  const named=P.nets.map((n,i)=>[n,i]).filter(([n])=>n.includes('.'));$('#ex-nets').innerHTML=named.map(([n])=>`<option value="${n.replace(/"/g,'&quot;')}">`).join('');
  const info=$('#ex-net');const modOf=i=>{const m=P.netmod[i]&127;return m?DM.modules[m-1]:null};
  const show=hit=>{if(!hit){view.pick=-1;info.innerHTML='<p class="muted">No wire there. Zoom in, or select a wire.</p>';view.kick();return}
    const i=hit.net;view.pick=i;const v=P.snap?P.snap[view.cycle-P.c0][i]:null;const m=modOf(i);
    info.innerHTML=`<p><code>${P.nets[i]}</code></p><p>Driven from ${m?`${D.modname[m]||m} <code>${m}</code>`:'a cell with no RTL name'}`+
      `${hit.layer?`; selected on ${hit.layer.replace('met','metal ')}`:''}.</p>`+(v!=null?`<p>${v===1?'High':v===0?'Low':'Unknown'} in cycle ${view.cycle.toLocaleString()}; it changed value ${P.activity[i].toLocaleString()} times over the whole test.</p>`:'');view.kick()};
  view.o.onPick=show;
  $('#ex-find').onchange=e=>{const i=P.nets.indexOf(e.target.value.trim());if(i<0){info.innerHTML='<p>No net has that name. Names with a dot are the ones synthesis kept from the RTL.</p>';return}
    const b=view.netBox(i);show({net:i});if(b)view.frame(b[0]-4,b[1]-4,b[2]+4,b[3]+4)};
  const xy=$('#ex-xy');view.o.onHover=(x,y)=>{xy.textContent=`x ${x.toFixed(2)} µm  y ${y.toFixed(2)} µm`};
  view.o.onFrame=v=>{scalebar($('#ex-scale'),v);labels($('#ex-labels'),v,v.focus&&Math.exp(v.cam.l)<6)};
  const c=()=>{const r=cv.getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]};
  // the exploded stack: drag turns it; select a wire again once it is flat
  const b3=$('#ex-3d');if(b3)b3.onclick=()=>{const on=view.tgt.tilt<0.5;view.tgt.tilt=on?1:0;if(on){view.tgt.yaw=-0.6;
      view.frame(-P.W*0.42,-P.H*0.62,P.W*1.42,P.H*1.62)}else{view.tgt.yaw=0;view.fit()}if(RM.matches)Object.assign(view.cam,view.tgt);
    b3.setAttribute('aria-pressed',on);b3.textContent=on?'Flat':'3D';$('#ex-net').innerHTML=on?'<p class="muted">The layers are pulled apart: drag sideways to turn the stack. Switch back to Flat to select wires.</p>':'<p class="muted">Select a wire to see its net.</p>';view.kick()};
  $('#ex-in').onclick=()=>view.zoomAt(...c(),1.8);$('#ex-out').onclick=()=>view.zoomAt(...c(),1/1.8);$('#ex-fit').onclick=()=>view.fit();
  view.fit(true);view.kick()}

window.atlasDie={story,explorer};
if(document.readyState!=='loading')story();else addEventListener('DOMContentLoaded',story);
const go=()=>{if((location.hash||'').startsWith('#layout'))explorer()};addEventListener('hashchange',go);go();
})();
"""

FPGA_JS = r"""
(()=>{
// =====================================================================
// The FPGA memory image in action, replayed from its own simulation
// (docs/atlas/fpga.json, make memboard). The board is a drawing; every
// byte, write, dispatch and completion is from the recorded run.
// =====================================================================
const D=JSON.parse(document.getElementById('atlas-data').textContent);const F=D.fpga,PH=D.fpgaphases||[];
const sv=document.getElementById('fpga');if(!sv||!F||!PH.length)return;
const RM=matchMedia('(prefers-reduced-motion: reduce)');const $=s=>document.querySelector(s);
const NS='http://www.w3.org/2000/svg';const el=(t,a,p)=>{const e=document.createElementNS(NS,t);for(const k in a)e.setAttribute(k,a[k]);(p||sv).appendChild(e);return e};
const hx=b=>b.toString(16).padStart(2,'0').toUpperCase();
// ---- the drawing
const B={host:[20,150,180,180,'signal','Host PC','testbench host'],ftdi:[270,200,76,64,'signal','USB-serial','FTDI bridge'],
  uart:[400,200,110,60,'signal','UART','8N1, both ways'],bridge:[540,200,120,60,'control','Serial bridge','commands A5 M R'],
  regs:[700,78,130,58,'control','Register map','ID, WD, ACTION'],sched:[862,78,286,58,'control','Scheduler (MOM)','costs, selects, tags'],
  xbar:[862,166,286,36,'control','Crossbar',''],
  eng0:[862,228,52,58,'compute','CPU','model'],eng1:[920,228,52,58,'compute','Vector','model'],eng2:[978,228,56,58,'compute','Array','real 4×4'],
  eng3:[1040,228,52,58,'compute','NTT','model'],eng4:[1098,228,52,58,'compute','Crypto','model'],
  bankA:[700,344,96,62,'memory','Bank A','operand'],bankB:[810,344,96,62,'memory','Bank B','operand'],bankC:[920,344,96,62,'memory','Bank C','results']};
el('rect',{x:240,y:18,width:942,height:446,rx:20,class:'fb-board'});
el('text',{x:262,y:48,class:'fb-cap'}).textContent='ECP5 evaluation board, plan '+F.plan+' (a drawing, not a photo)';
el('rect',{x:270,y:330,width:76,height:40,rx:6,class:'fb-part'});el('text',{x:308,y:355,class:'fb-s','text-anchor':'middle'}).textContent='12 MHz';
// the FPGA package, with its pins along the edges
el('rect',{x:380,y:60,width:790,height:392,rx:10,class:'fb-fpga'});
for(let i=0;i<38;i++){el('rect',{x:396+i*20.2,y:52,width:8,height:8,class:'fb-pin'});el('rect',{x:396+i*20.2,y:452,width:8,height:8,class:'fb-pin'})}
for(let i=0;i<19;i++){el('rect',{x:372,y:76+i*19.5,width:8,height:8,class:'fb-pin'});el('rect',{x:1170,y:76+i*19.5,width:8,height:8,class:'fb-pin'})}
el('text',{x:400,y:430,class:'fb-cap'}).textContent='ECP5-85F FPGA';el('text',{x:862,y:304,class:'fb-s'}).textContent='dashed: latency models; only the array is real in this image';
// wires: id, path, role
const W=[['w-rx','M200 222H270','signal'],['w-tx','M270 242H200','signal'],['w-fu','M346 222H400','signal'],['w-uf','M400 242H346','signal'],
  ['w-ub','M510 230H540','signal'],['w-br','M660 222H680V107H700','control'],['w-rs','M830 107H862','control'],
  ['w-sx','M1005 136V166','control'],['w-xe','M1005 202V228','control'],['w-bm','M660 238H680V375H700','memory'],
  ['w-ab','M748 344V318H1006V286','memory'],['w-bb','M858 344V318','memory'],['w-ec','M1006 286V330H968V344','memory']];
const wires={};W.forEach(([id,d,r])=>{wires[id]=el('path',{d,class:'fb-w r-'+r,id})});
const box={};for(const [id,[x,y,w,h,role,a,b]] of Object.entries(B)){const g=el('g',{class:'fb-b r-'+role+(/eng[0134]/.test(id)?' model':'')+(id==='host'?' host':''),id:'fb-'+id});
  const ty=id==='host'?y+22:y+(b?h/2-2:h/2+5);el('rect',{x,y,width:w,height:h,rx:8},g);el('text',{x:x+w/2,y:ty,class:'fb-t','text-anchor':'middle'},g).textContent=a;
  if(b)el('text',{x:x+w/2,y:ty+17,class:'fb-s','text-anchor':'middle'},g).textContent=b;box[id]=g}
// the host's terminal: the last bytes each way
const term=el('g',{class:'fb-term'});
const beads=el('g',{});
const WIRES={reg:['w-rx','w-fu','w-ub','w-br','w-rs','w-tx','w-uf'],mem:['w-rx','w-fu','w-ub','w-bm','w-tx','w-uf'],read:['w-rx','w-fu','w-ub','w-bm','w-tx','w-uf'],
  disp:['w-rs','w-sx','w-xe'],comp:['w-ab','w-bb','w-ec','w-xe','w-sx'],other:['w-rx','w-fu','w-ub']};
// ---- state
let i=0,c=PH[0].c0,timer=null,t0=0;const cap=$('#fpga-cap'),clk=$('#fpga-clock'),sl=$('#fpga-scrub'),play=$('#fpga-play');sl.max=PH.length-1;
const ev=F.events;
function draw(){const p=PH[i];for(const [id,g] of Object.entries(box))g.classList.toggle('on',p.blocks.includes(id)||(id==='ftdi'&&p.blocks.includes('uart')));
  const lit=WIRES[p.kind]||[];for(const [id,w] of Object.entries(wires))w.classList.toggle('on',lit.includes(id));
  // bytes on the cable: those sent in the 44 cycles before now travel along it
  beads.innerHTML='';for(const e of ev){if(e.k!=='in'&&e.k!=='out')continue;const age=c-e.c;if(age<0||age>44)continue;
    const f=age/44,x=e.k==='in'?200+f*200:400-f*200,y=e.k==='in'?222:242;
    el('circle',{cx:x,cy:y,r:9,class:'fb-bead '+(e.k==='in'?'r-signal':'r-memory')},beads);el('text',{x,y:y+3.5,class:'fb-bx','text-anchor':'middle'},beads).textContent=hx(e.b)}
  // the terminal
  const seen=ev.filter(e=>(e.k==='in'||e.k==='out')&&e.c<=c).slice(-7);term.innerHTML='';
  seen.forEach((e,k)=>{el('text',{x:36,y:214+k*16,class:'fb-m '+(e.k==='in'?'in':'out')},term).textContent=(e.k==='in'?'→ ':'← ')+hx(e.b)+(e.b>=32&&e.b<127?'  '+String.fromCharCode(e.b):'')});
  cap.textContent=`Cycle ${Math.round(c).toLocaleString()}: ${p.text}.`;clk.textContent=`${i+1} / ${PH.length}`;sl.value=i;
  box.eng2.classList.toggle('busy',(F.busy.filter(b=>b[0]<=c).pop()||[0,0])[1]&4?true:false)}
function go(k){i=Math.max(0,Math.min(PH.length-1,k));c=PH[i].c0;draw()}
function stop(){if(timer){cancelAnimationFrame(timer);timer=null}play.setAttribute('aria-pressed','false');play.setAttribute('aria-label','Play');play.innerHTML='<svg aria-hidden="true"><use href="#i-play"/></svg>'}
function tick(now){const p=PH[i];const dur=RM.matches?1600:Math.max(1400,Math.min(3200,(p.c1-p.c0)*1.2));
  if(!t0)t0=now;const f=Math.min(1,(now-t0)/dur);c=RM.matches?p.c1:p.c0+(p.c1-p.c0+46)*f;draw();
  if(f>=1){t0=0;if(i>=PH.length-1){stop();return}i++;c=PH[i].c0}timer=requestAnimationFrame(tick)}
play.onclick=()=>{if(timer){stop();return}if(i>=PH.length-1)go(0);play.setAttribute('aria-pressed','true');play.setAttribute('aria-label','Pause');
  play.innerHTML='<svg aria-hidden="true"><use href="#i-pause"/></svg>';t0=0;timer=requestAnimationFrame(tick)};
$('#fpga-prev').onclick=()=>{stop();go(i-1)};$('#fpga-next').onclick=()=>{stop();go(i+1)};sl.oninput=()=>{stop();go(+sl.value)};
$('#fpga-prov').textContent=`${F.label} · ${F.result} · ${F.command} · repo ${String(F.repo_commit).slice(0,10)} · ${F.cycles.toLocaleString()} cycles of ${F.clock_ns} ns in the bench · ${F.serial_note} · not a board capture`;
const p=F.pnr;if(p)$('#fpga-pnr').innerHTML=`<dt>Look-up tables</dt><dd class="num">${p.luts.toLocaleString()}</dd><dt>Flip-flops</dt><dd class="num">${p.ffs.toLocaleString()}</dd>`+
  `<dt>Multipliers</dt><dd class="num">${p.mult}</dd><dt>Fastest clock</dt><dd class="num">${p.fmax.toFixed(2)} MHz</dd><dt>Board runs</dt><dd>none yet</dd>`;
go(0);
})();
"""

NUM_JS = r"""
(()=>{
// one number per screen: its fill is exposed as the block scrolls to the middle
const RM=matchMedia('(prefers-reduced-motion: reduce)');const bs=[...document.querySelectorAll('.bignum')];
function upd(){if(RM.matches){bs.forEach(b=>b.style.setProperty('--p',1));return}const vh=innerHeight;
  bs.forEach(b=>{const r=b.getBoundingClientRect();const p=Math.max(0,Math.min(1,(vh-r.top)/(vh*0.75)));b.style.setProperty('--p',p.toFixed(3))})}
addEventListener('scroll',upd,{passive:true});addEventListener('resize',upd);upd();
// the FPGA board tilts a little toward the pointer (fine pointers only)
const st=document.querySelector('.fpgastage'),sv=st&&st.querySelector('svg');
if(st&&sv&&matchMedia('(hover:hover) and (pointer:fine)').matches){
  st.addEventListener('pointermove',e=>{if(RM.matches)return;const r=st.getBoundingClientRect();const x=(e.clientX-r.left)/r.width-.5,y=(e.clientY-r.top)/r.height-.5;
    sv.style.transform=`rotateY(${(x*7).toFixed(2)}deg) rotateX(${(-y*6).toFixed(2)}deg)`});
  st.addEventListener('pointerleave',()=>{sv.style.transform=''})}
})();
"""

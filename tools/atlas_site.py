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
    return spec, cards, derived, traces, phys, flow, timing


# ---------------------------------------------------------------------------
# freshness: the derived data must describe the files as they are now
# ---------------------------------------------------------------------------
def stale_sources(derived, traces, phys):
    def sha(p):
        f = ROOT / p
        return hashlib.sha256(f.read_bytes()).hexdigest() if f.exists() else None
    bad = []
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
        sym = T.SYMBOL[blk["role"]]
        out.append(f'<g class="node r-{blk["role"]}" data-id="{blk["id"]}" tabindex="0" role="button" '
                   f'aria-label="{esc(blk["label"])}: {esc(blk["sub"])}. Open its card.">'
                   f'<rect x="{x}" y="{y}" width="{BW}" height="{BH}" rx="8"/>'
                   f'<text class="sym" x="{x + 12}" y="{y + 21}">{sym}</text>'
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
    W, Hh = 860, 500
    cx, cy, cw, ch = 300, 60, 260, 300
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
          ("Check", "make sky130, make lint")]),
        ("fpga", "FPGA images",
         f"{len(plans)} build plans. Place and route recorded for {len(pnr)} ECP5 images. No image has run on a board.",
         [("Built", ", ".join(pnr)),
          ("Host paths", "serial on every image; serial and JTAG on Basys 3 only"),
          ("Board runs", "none yet")]),
    ]


def render(metrics):
    spec, cards, derived, traces, phys, flow, timing = load()
    problems = stale_sources(derived, traces, phys)
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
            return "<table class='io'><thead><tr><th>Port</th><th>Width</th><th>Meaning</th></tr></thead><tbody>" + "".join(
                f"<tr><td><code>{esc(r.get('name'))}</code></td><td>{esc(r.get('width', ''))}</td>"
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
  <header><span class="sym" aria-hidden="true">{T.SYMBOL[b["role"]]}</span>
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
                       f"<td>{r['len']}</td><td>{esc(r['access'])}</td><td>{esc(r['desc'])}</td></tr>"
                       for r in rg["registers"])
    status_bits = "".join(f"<tr><td>{f['msb']}{'' if f['msb'] == f['lsb'] else ':' + str(f['lsb'])}</td>"
                          f"<td><code>{esc(f['name'])}</code></td></tr>" for f in rg["status"])
    result_bits = "".join(f"<tr><td>{f['msb']}:{f['lsb']}</td><td><code>{esc(f['name'])}</code></td></tr>"
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
        "physical": phys, "roles": list(T.ROLES), "symbols": T.SYMBOL,
        "regs": {r["addr"]: r["name"] for r in rg["registers"]},
        "reglen": {r["addr"]: r["len"] for r in rg["registers"]},
        "flow": flow,
    }
    blob = json.dumps(data, separators=(",", ":"), sort_keys=True).replace("</", "<\\/")

    st = status_cards(timing, metrics, derived)
    st_html = "".join(
        f'<section class="target t-{k}"><h3>{esc(title)}</h3><p>{esc(sub)}</p><dl>' +
        "".join(f"<dt>{esc(a)}</dt><dd>{esc(b2)}</dd>" for a, b2 in rows) + "</dl></section>"
        for k, title, sub, rows in st)

    cx = traces.get("crossover")
    tour = tour_steps(cx)
    t_last = timing[-1]
    stale_note = ("" if not problems else
                  '<div class="callout warn" role="status"><b>Generated data is behind the sources.</b> ' +
                  "; ".join(esc(p) for p in problems[:6]) + "</div>")

    return PAGE.format(
        css=CSS, js=JS, data=blob, light=T.css_vars(T.LIGHT), dark=T.css_vars(T.DARK),
        status=st_html, tour=tour, views="".join(views), build_opts=build_opts,
        cards="".join(card_html), pin_svg=pin_svg(tp), pin_rows=pin_rows, reg_rows=reg_rows,
        status_bits=status_bits, result_bits=result_bits, ver_rows=ver_rows, pend=pend,
        contra_rows=contra_rows or "<tr><td colspan=3>None recorded.</td></tr>",
        trace_rows=trace_rows, labels="".join(f"<li><b>{esc(k)}</b>: {esc(v)}</li>" for k, v in LABELS.items()),
        tile_ver=esc(t_last["version"]), period=t_last["period_ns"],
        clock_mhz=f"{tp['clock_hz'] / 1e6:.2f}", tiles=esc(tp["tiles"]), stale=stale_note,
        frame=esc(rg["frame"]), phys_note=phys_note(phys, timing), flow=flow_html(flow),
        repo=REPO, n_blocks=len(spec["blocks"]), n_builds=len(builds), n_traces=len(traces),
        videos=videos_html(),
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
        return {"ENG_CPU": "CPU", "ENG_SIMD": "vector unit", "ENG_TPU": "array", "ENG_NTT": "butterflies",
                "ENG_CRYPTO": "crypto"}.get(n, n)
    costs = ", ".join(f"{nm(r['name'])} {r['cost']}" for r in s2["rows"] if r["why"] != "cannot do this operation or data type")
    rej = ", ".join(nm(r["name"]) for r in s2["rows"] if r["why"] == "cannot do this operation or data type")
    c = cal[-1] if cal else None
    steps = [
        ("1", "A job arrives", f"A 128-bit descriptor over SPI: {d2['op'].replace('OPC_', '')} on "
         f"{d2['dtype'].replace('DT_', '')}, {d2['m']}×{d2['n']}×{d2['kk']}.", d2["c"]),
        ("2", "Every engine is costed", f"One shared cost engine walks the rows, two cycles each: {costs}. "
         f"Refused before any cost is compared: {rej} cannot do this operation.", s2["c"] - 9),
        ("3", "The cheapest wins a tag", f"{nm(next(r['name'] for r in s2['rows'] if r['chosen']))} "
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


def flow_html(flow):
    if not flow:
        return ('<p class="callout warn"><b>Blocked by missing evidence.</b> No harden run has been summarised. '
                'Run <code>make atlas-flow</code>.</p>')
    rows = "".join(f"<li class='fstep{'' if s['detail'] else ' quiet'}'><span class='fn'>{esc(s['name'])}</span><span class='fd'>{esc(s['detail'])}</span></li>"
                   for s in flow["steps"])
    return (f"<p><span class='kind'>Recorded Tool Output</span></p><p>Every step of LibreLane run <code>{esc(flow['run'])}</code> ({esc(flow['what'])}), in order, "
            f"with what its own log or report says.</p><ol class='flow'>{rows}</ol>")


# ---------------------------------------------------------------------------
CSS = r"""
:root{color-scheme:light dark;--sans:"IBM Plex Sans","Inter",ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--r:10px}
*,*::before,*::after{box-sizing:border-box}
html{scroll-padding-top:72px}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 var(--sans);
 --gridc:color-mix(in srgb,var(--line2) 45%,transparent);
 background-image:linear-gradient(var(--gridc) 1px,transparent 1px),linear-gradient(90deg,var(--gridc) 1px,transparent 1px);
 background-size:32px 32px;background-attachment:fixed}
a{color:var(--signal)}a:hover{text-decoration-thickness:2px}
code,kbd,.num{font-family:var(--mono);font-size:.88em}
code{background:var(--surface);border:1px solid var(--line2);border-radius:5px;padding:0 .3em}
.skip{position:absolute;left:-9999px;top:8px;z-index:20;background:var(--raised);color:var(--ink);padding:8px 12px;border-radius:8px}
.skip:focus{left:12px}
:focus-visible{outline:3px solid var(--signal);outline-offset:2px;border-radius:4px}
.wrap{max-width:1240px;margin:0 auto;padding:0 16px}
.top{position:sticky;top:0;z-index:10;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(8px);
 border-bottom:1px solid var(--line)}
.top .wrap{display:flex;align-items:center;gap:16px;min-height:60px;flex-wrap:wrap}
.brand{font-weight:700;letter-spacing:-.01em;text-decoration:none;color:var(--ink);display:flex;gap:10px;align-items:center}
.brand .mk{width:22px;height:22px;border:2px solid var(--ink);border-radius:5px;display:grid;place-items:center;font:700 11px var(--mono)}
.brand small{font-weight:400;color:var(--dim)}
nav.tabs{display:flex;gap:2px;flex-wrap:wrap;flex:1}
nav.tabs a{padding:6px 10px;border-radius:7px;color:var(--ink2);text-decoration:none;font-size:14.5px}
nav.tabs a[aria-current="page"]{background:var(--raised);color:var(--ink);box-shadow:inset 0 0 0 1px var(--line)}
.theme{display:flex;gap:2px;border:1px solid var(--line);border-radius:8px;padding:2px}
.theme button{font:13px var(--sans);background:none;border:0;color:var(--ink2);padding:4px 8px;border-radius:6px;cursor:pointer}
.theme button[aria-pressed="true"]{background:var(--raised);color:var(--ink)}
main{padding:24px 0 80px}
section.panel{display:block}
.js section.panel[hidden]{display:none}
h1{font-size:clamp(34px,6vw,60px);line-height:1.05;letter-spacing:-.03em;margin:.2em 0 .2em}
h2{font-size:clamp(22px,3vw,30px);letter-spacing:-.015em;margin:1.6em 0 .4em}
h3{font-size:18px;margin:0}
h4{margin:1em 0 .3em;font-size:15px}
h5{margin:1em 0 .2em;font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:var(--dim)}
p{max-width:76ch}
.eyebrow{font:600 12.5px var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--signal)}
.lede{font-size:clamp(18px,2.2vw,21px);color:var(--ink2);max-width:62ch}
.muted{color:var(--dim)}
.callout{border-left:4px solid var(--control);background:var(--control-t);padding:12px 16px;border-radius:0 var(--r) var(--r) 0;max-width:86ch}
.callout.warn{border-color:var(--danger);background:var(--danger-t)}
.actions{display:flex;gap:10px;flex-wrap:wrap;margin:22px 0}
.btn{display:inline-flex;align-items:center;gap:8px;padding:10px 16px;border-radius:9px;border:1px solid var(--line);
 background:var(--raised);color:var(--ink);text-decoration:none;font-weight:600;font-size:15px}
.btn.primary{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.targets{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(min(100%,320px),1fr));margin-top:18px}
.target{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);padding:16px 18px}
.target p{color:var(--ink2);font-size:14.5px;margin:.3em 0 .6em}
.target dl{display:grid;grid-template-columns:auto 1fr;gap:4px 12px;margin:0;font-size:14px}
.target dt{color:var(--dim)}.target dd{margin:0}
.t-tile{border-top:3px solid var(--control)}.t-chip{border-top:3px solid var(--compute)}.t-fpga{border-top:3px solid var(--memory)}
ol.tour{list-style:none;padding:0;display:grid;gap:10px;grid-template-columns:repeat(auto-fit,minmax(min(100%,250px),1fr))}
.tourstep{all:unset;cursor:pointer;display:grid;gap:4px;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);
 padding:14px 16px;height:100%;box-sizing:border-box}
.tourstep:hover{border-color:var(--signal)}
.tourstep .n{font:700 13px var(--mono);color:var(--signal)}
.tourstep .tt{font-weight:700}.tourstep .td{color:var(--ink2);font-size:14px}
.labels{padding-left:1.2em;font-size:14px;max-width:90ch}.labels li{margin:2px 0}
.legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:14px;margin:8px 0;padding:0;list-style:none}
.legend li{display:flex;align-items:center;gap:6px}
.legend .sw{width:12px;height:12px;border-radius:3px;display:inline-block}
.r-signal{--rc:var(--signal);--rt:var(--signal-t)}.r-control{--rc:var(--control);--rt:var(--control-t)}
.r-compute{--rc:var(--compute);--rt:var(--compute-t)}.r-memory{--rc:var(--memory);--rt:var(--memory-t)}
.r-secure{--rc:var(--secure);--rt:var(--secure-t)}
.legend .sw{background:var(--rc)}
.toolbar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:10px 0}
select,input[type=range]{font:inherit;color:var(--ink);background:var(--raised);border:1px solid var(--line);border-radius:7px;padding:5px 8px;max-width:100%}
.scroll{overflow-x:auto;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);padding:8px}
svg.logical{display:block;min-width:640px;width:100%;height:auto}
.node rect{fill:var(--rt);stroke:var(--rc);stroke-width:1.4}
.node:hover rect,.node:focus rect,.node.on rect{stroke-width:2.6}
.node .nl{font:600 13px var(--sans);fill:var(--ink)}
.node .ns{font:11px var(--mono);fill:var(--ink2)}
.node .sym{font:13px var(--sans);fill:var(--rc)}
.node{cursor:pointer;outline:none}
.edge{fill:none;stroke:var(--line);stroke-width:1.5}
.edge.hot{stroke:var(--rc);stroke-width:2.6}
figcaption{font-size:13.5px;color:var(--dim);margin-top:6px}
details.textalt{margin:8px 0}
details.textalt summary,details.more summary,details.expert summary{cursor:pointer;color:var(--signal);font-size:14px}
.cardfilters{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.cards{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(min(100%,340px),1fr));margin-top:12px;align-items:start}
.card{background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--rc);border-radius:var(--r);padding:14px 16px}
.card header{display:flex;gap:8px;align-items:baseline}
.card .sym{color:var(--rc)}.card .role{margin-left:auto;font:12px var(--mono);color:var(--dim)}
.card .job{margin:.4em 0;font-size:15px}
.card.flash{box-shadow:0 0 0 3px var(--rc)}
.avail{list-style:none;padding:0;margin:6px 0;display:flex;flex-wrap:wrap;gap:4px}
.avail li{font-size:12px;border:1px solid var(--line);border-radius:999px;padding:1px 8px;color:var(--ink2)}
.avail li.none{border-style:dashed}
.card dl{margin:8px 0 0}.card dt{font-weight:650;font-size:13.5px;margin-top:10px}.card dd{margin:2px 0 0;font-size:14px;color:var(--ink2)}
table{border-collapse:collapse;width:100%;font-size:14px}
th,td{text-align:left;padding:6px 9px;border-bottom:1px solid var(--line2);vertical-align:top}
thead th{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--dim)}
.tablewrap{overflow-x:auto;background:var(--surface);border:1px solid var(--line);border-radius:var(--r)}
table.io{font-size:13px}
ul.cites{font:12px var(--mono);color:var(--dim)}.warnline{color:var(--control)}
.grid2{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr))}
/* player */
.player{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);padding:14px}
.phead{display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.kind{font:700 11.5px var(--mono);letter-spacing:.08em;text-transform:uppercase;border:1.5px solid currentColor;border-radius:999px;padding:2px 9px;color:var(--signal)}
.prov{font:12px var(--mono);color:var(--dim);overflow-wrap:anywhere}
.controls{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:10px 0}
.controls button{font:600 14px var(--sans);min-width:40px;min-height:36px;border:1px solid var(--line);background:var(--raised);color:var(--ink);border-radius:8px;cursor:pointer;padding:0 10px}
.controls button[aria-pressed="true"]{background:var(--ink);color:var(--bg)}
.controls input[type=range]{flex:1;min-width:160px}
.clock{font:600 14px var(--mono);min-width:12ch}
.caption{min-height:3.2em;font-size:16px;padding:10px 12px;border-radius:8px;background:var(--raised);border:1px solid var(--line2)}
.stage{display:block;width:100%;height:auto;min-width:640px}
svg.tpu{display:block;width:100%;max-width:620px;height:auto;margin:0 auto}
.st rect{fill:var(--raised);stroke:var(--line);stroke-width:1.3}
.st.on rect{fill:var(--rt);stroke:var(--rc);stroke-width:2.4}
.st text{font:600 12.5px var(--sans);fill:var(--ink);text-anchor:middle}
.st text.sub{font:11px var(--mono);fill:var(--ink2)}
.sedge{stroke:var(--line);stroke-width:1.5;fill:none}
.sedge.on{stroke:var(--signal);stroke-width:2.6}
.pkt{fill:var(--signal)}
.costs .bar{height:12px;border-radius:3px;background:var(--control);display:inline-block;vertical-align:middle}
.costs td.why{color:var(--dim)}
.costs tr.win td{font-weight:700}
.costs tr.rej td:first-child::before{content:"✕ ";color:var(--danger)}
.costs tr.win td:first-child::before{content:"✓ ";color:var(--ok)}
.tags{display:flex;gap:8px}
.tagc{flex:1;border:1.5px solid var(--line);border-radius:8px;padding:6px;text-align:center;font:600 13px var(--mono)}
.tagc.busy{background:var(--control-t);border-color:var(--control)}
.bytes{font:13px var(--mono);overflow-wrap:anywhere}
.wave{display:block;width:100%;height:auto}
.wave text{font:11px var(--mono);fill:var(--ink2)}
.wave .w{fill:none;stroke:var(--signal);stroke-width:1.4}
.wave .cur{stroke:var(--control);stroke-width:1.5}
.wave .bus{fill:var(--signal-t);stroke:var(--signal);stroke-width:1}
.chart{display:block;width:100%;height:auto}
.chart text{font:11px var(--mono);fill:var(--ink2)}
figure.film{margin:0}figure.film video{width:100%;height:auto;border:1px solid var(--line);border-radius:var(--r);background:var(--surface)}
canvas#phys{width:100%;max-width:820px;height:auto;display:block;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);touch-action:none}
.physlegend{list-style:none;padding:0;columns:2 260px;font-size:13.5px}
.physlegend label{display:flex;gap:6px;align-items:center;cursor:pointer}
.physlegend .sw{width:11px;height:11px;border-radius:2px}
svg.pins{display:block;width:100%;height:auto;min-width:620px}
svg.pins .die{fill:var(--raised);stroke:var(--ink);stroke-width:1.6}
svg.pins .dl{font:700 15px var(--mono);fill:var(--ink)}svg.pins .ds{font:12px var(--mono);fill:var(--ink2)}
svg.pins line.used{stroke:var(--signal);stroke-width:2}svg.pins line.unused{stroke:var(--line);stroke-width:2;stroke-dasharray:3 3}
svg.pins rect.used{fill:var(--signal)}svg.pins rect.unused{fill:var(--line)}
svg.pins .pn{font:11.5px var(--mono);fill:var(--ink)}
ol.flow{list-style:none;padding:0;counter-reset:f;display:grid;gap:6px}
.fstep{counter-increment:f;display:grid;grid-template-columns:3.2em minmax(10em,16em) 1fr;gap:10px;align-items:baseline;
 background:var(--surface);border:1px solid var(--line2);border-radius:8px;padding:6px 10px;font-size:14px}
.fstep::before{content:counter(f);font:700 12px var(--mono);color:var(--control)}
.fstep.quiet{opacity:.62}.fstep .fn{font-weight:650}.fstep .fd{color:var(--ink2);font-family:var(--mono);font-size:12.5px}
footer{border-top:1px solid var(--line);padding:24px 0 48px;color:var(--dim);font-size:13.5px}
@media (max-width:760px){.top{position:static}.top .wrap{gap:6px 10px;padding-top:8px;padding-bottom:6px}
 nav.tabs{order:3;flex:1 1 100%;flex-wrap:nowrap;overflow-x:auto;scrollbar-width:thin}nav.tabs a{white-space:nowrap}
 .theme{margin-left:auto}html{scroll-padding-top:8px}}
@media (max-width:640px){.fstep{grid-template-columns:2.4em 1fr}.fstep .fd{grid-column:2}nav.tabs a{padding:5px 7px;font-size:13.5px}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important;scroll-behavior:auto!important}}
@media print{.top,.controls,.theme{display:none}.js section.panel[hidden]{display:block}body{background:#fff}}
"""

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HYDRA-130 Silicon Atlas</title>
<meta name="description" content="HYDRA-130: a hardware scheduler that costs compute engines, dispatches to the cheapest eligible one and calibrates itself. Blocks, builds, recorded traces and evidence, generated from the repository.">
<style>
:root{{{light}}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{{dark}}}}}
:root[data-theme="dark"]{{{dark}}}
{css}
</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="top"><div class="wrap">
  <a class="brand" href="#overview"><span class="mk" aria-hidden="true">H</span>HYDRA-130 <small>Silicon Atlas</small></a>
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

<main id="main" class="wrap">
{stale}

<section class="panel" id="overview" aria-labelledby="h-overview">
  <p class="eyebrow">SkyWater 130 nm · Tiny Tapeout · FPGA</p>
  <h1 id="h-overview">HYDRA-130</h1>
  <p class="lede">A hardware scheduler that predicts how long each compute engine would take a job, sends the job
  to the cheapest engine allowed to run it, measures what really happened and corrects its own model.</p>
  <p class="callout"><b>Status by revision.</b> The Tiny Tapeout tile {tile_ver} is the scheduler alone and has a clean
  sign-off record from one harden; it is not fabricated or tested silicon. The full OpenFrame chip is simulated and has never
  been hardened. No FPGA image has run on a board. Security blocks are checked IP in no build.</p>
  <div class="actions">
    <a class="btn primary" href="#architecture">Explore architecture</a>
    <a class="btn" href="#demos">Run a demo</a>
    <a class="btn" href="#build">Build</a>
    <a class="btn" href="#evidence">Evidence</a>
  </div>
  <h2>A short tour of one decision</h2>
  <p class="muted">Numbers from a recorded run of the tile's own test <code>test_roofline_crossover</code>. Select a step to replay it.</p>
  <ol class="tour">{tour}</ol>
  <h2>Three targets, kept apart</h2>
  <div class="targets">{status}</div>
  <p class="muted">Maintained by <a href="https://github.com/Normansrule">@Normansrule</a>. {n_blocks} blocks,
  {n_builds} builds read from the compiler, {n_traces} recorded traces.</p>
</section>

<section class="panel" id="architecture" aria-labelledby="h-arch">
  <h2 id="h-arch">Logical architecture</h2>
  <p>Pick a build. A box is drawn only if its module was elaborated when that build's own make target or plan was
  compiled (<code>tools/atlas_derive.py</code>). <b>Positions are logical, not die locations</b>; where cells really
  are is the <a href="#layout">Physical layout</a> tab. Select a box for its card.</p>
  <div class="toolbar"><label for="buildsel">Build</label><select id="buildsel">{build_opts}</select></div>
  <ul class="legend" aria-label="Colour key">
    <li class="r-signal"><span class="sw"></span>▸ signal: data and requests</li>
    <li class="r-control"><span class="sw"></span>◆ control: decisions, registers, timing</li>
    <li class="r-compute"><span class="sw"></span>■ compute: engines</li>
    <li class="r-memory"><span class="sw"></span>▤ memory: banks, streamers</li>
    <li class="r-secure"><span class="sw"></span>◈ security IP</li>
  </ul>
  {views}
</section>

<section class="panel" id="layout" aria-labelledby="h-layout">
  <h2 id="h-layout">Physical layout of the tile</h2>
  {phys_note}
  <p>There are no module rectangles on a flattened layout. Each dot is one placed standard cell. A cell is coloured by an
  RTL instance only when the netlist says so: <b>named</b> cells drive a net that keeps that instance's hierarchical name
  (mostly registers); <b>inferred</b> cells (lighter) drive only that instance's named registers. Everything else is shown
  as unattributed, buffers, clock tree, hold or antenna cells. One module's cells are spread across the die, which is the point.</p>
  <div class="grid2">
    <div><canvas id="phys" width="820" height="620" role="img" aria-label="Placed cells of the tile, coloured by RTL instance. Counts are in the list beside it."></canvas>
      <p class="muted" id="physinfo">Scripting is needed to draw the cells; the counts are listed here.</p></div>
    <div><h4>Instances</h4><ul class="physlegend" id="physlegend"></ul>
      <figure class="film"><img src="media/layout.png" alt="The tile's real layout, every cell and wire, rendered from its hardened GDS by Tiny Tapeout's own tool" style="width:100%;height:auto;border-radius:10px;border:1px solid var(--line)" loading="lazy">
      <figcaption>The real layout of the same run, rendered from its GDS by Tiny Tapeout's tool (<code>make render-layout</code>).</figcaption></figure>
      <details class="textalt"><summary>3D view</summary><p>Deferred: the 2D view is complete and needs no download.
      A 3D view would add depth only for metal layers, which this data does not include.</p></details></div>
  </div>
</section>

<section class="panel" id="blocks" aria-labelledby="h-blocks">
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

<section class="panel" id="demos" aria-labelledby="h-demos">
  <h2 id="h-demos">Demos, replayed from recorded runs</h2>
  <ul class="labels">{labels}</ul>
  <p class="muted">Motion between two recorded samples is presentation, not extra hardware cycles: the cycle counter shows
  only recorded cycles.</p>
  <div class="player" id="player">
    <div class="phead"><label for="tracesel">Trace</label><select id="tracesel"></select><span class="kind" id="tkind"></span></div>
    <p class="prov" id="tprov"></p>
    <div class="controls" role="group" aria-label="Playback">
      <button type="button" id="b-reset" aria-label="Back to the start">⏮</button>
      <button type="button" id="b-prev" aria-label="Previous event">◀◀</button>
      <button type="button" id="b-cm" aria-label="One cycle back">−1</button>
      <button type="button" id="b-play" aria-pressed="false" aria-label="Play">▶ Play</button>
      <button type="button" id="b-cp" aria-label="One cycle forward">+1</button>
      <button type="button" id="b-next" aria-label="Next event">▶▶</button>
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
      <div><h4>Engine costs and why each lost</h4><div class="tablewrap"><table class="costs" id="costs"><thead><tr><th>Engine</th><th>Cost</th><th></th><th>Outcome</th></tr></thead><tbody></tbody></table></div>
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

<section class="panel" id="tile" aria-labelledby="h-tile">
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
  <div class="tablewrap"><table><thead><tr><th>Addr</th><th>Name</th><th>Bytes</th><th>Access</th><th>Fields</th></tr></thead><tbody>{reg_rows}</tbody></table></div>
  <div class="grid2"><div><h4>STATUS bits</h4><div class="tablewrap"><table><tbody>{status_bits}</tbody></table></div></div>
  <div><h4>RESULT bits</h4><div class="tablewrap"><table><tbody>{result_bits}</tbody></table></div></div></div>
  <h3 style="margin-top:20px">A worked SPI session</h3>
  <p>The frames below are the real bytes of two recorded tests: a descriptor staged and dispatched, and a malformed frame refused.</p>
  <div id="worked"></div>
</section>

<section class="panel" id="build" aria-labelledby="h-build">
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

<section class="panel" id="evidence" aria-labelledby="h-ev">
  <h2 id="h-ev">Evidence</h2>
  <p>Each check names the command that reproduces it. A proof establishes its property under its stated assumptions
  and nothing wider; a simulation establishes agreement on the tested inputs.</p>
  <div class="tablewrap"><table><thead><tr><th>Check</th><th>Scale</th><th>Kind</th><th>Run with</th></tr></thead><tbody>{ver_rows}</tbody></table></div>
  <h3>Recorded traces on this page</h3>
  <div class="tablewrap"><table><thead><tr><th>Trace</th><th>Label</th><th>Test</th><th>Result</th><th>Commit</th></tr></thead><tbody>{trace_rows}</tbody></table></div>
  <h3>Where the documents and the RTL disagree</h3>
  <p>Found while writing the cards, by reading the RTL and, where marked VERIFIED-SIM, by simulation. The atlas, the
  READMEs and the figures follow the RTL; the RTL, its comments and the other documents are not changed by this work.</p>
  <div class="tablewrap"><table><thead><tr><th>Claim</th><th>What the RTL does</th><th>Status</th></tr></thead><tbody>{contra_rows}</tbody></table></div>
  <h3>Not done</h3><ul>{pend}</ul>
</section>
</main>

<footer><div class="wrap">
  <p>Maintained by <a href="https://github.com/Normansrule">@Normansrule</a>. Apache 2.0; board files and submodules keep their own licences (see NOTICE).
  Generated by <code>tools/gen_site.py</code> from <code>docs/atlas/</code>, <code>docs/metrics.json</code>, <code>docs/timing.json</code>
  and the tile's RTL; <code>make site-check</code> fails if this page is out of date. Source: <a href="https://github.com/{repo}">{repo}</a>.</p>
</div></footer>
<script id="atlas-data" type="application/json">{data}</script>
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
  $$('.theme button').forEach(b=>b.setAttribute('aria-pressed',b.dataset.theme===t));drawPhys();renderAll();}
$$('.theme button').forEach(b=>b.onclick=()=>setTheme(b.dataset.theme));
// ---------- tabs (hash routing)
const panels=$$('section.panel'), links=$$('nav.tabs a');
function route(){let id=(location.hash||'#overview').slice(1);let target=null;
  if(id.startsWith('card-')){target=id;id='blocks'}
  if(!panels.some(p=>p.id===id))id='overview';
  panels.forEach(p=>p.hidden=p.id!==id);links.forEach(a=>a.setAttribute('aria-current',a.getAttribute('href')==='#'+id?'page':'false'));
  if(target){const c=document.getElementById(target);if(c){c.querySelector('details.more').open=true;c.scrollIntoView();c.classList.add('flash');setTimeout(()=>c.classList.remove('flash'),1600)}}
  else window.scrollTo(0,0);
  if(id==='layout')drawPhys();if(id==='demos')renderAll();}
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
// ---------- physical layout
const P=D.physical, cv=$('#phys');
const palette=['signal','control','compute','memory','secure'];
let physOn={};
function colourFor(k,i){const base=k.replace(/^~/,'');const order=['u_spi','u_regs','u_mom','u_mom.u_sb','u_mom.u_cal','u_mom.g_shared','u_mom.g_shared.u_ce','u_mom.u_feat','u_rst_sync'];
  const j=order.indexOf(base);return css('cat'+(((j<0?i:j)%9)+1))}
function drawPhys(){if(!P||!cv)return;const ctx=cv.getContext('2d');const [x0,y0,x1,y1]=P.die_um;
  const W=cv.width,Hc=cv.height,s=Math.min((W-20)/(x1-x0),(Hc-20)/(y1-y0));
  ctx.fillStyle=css('surface');ctx.fillRect(0,0,W,Hc);ctx.strokeStyle=css('ink');ctx.lineWidth=1.2;
  ctx.strokeRect(10,10,(x1-x0)*s,(y1-y0)*s);
  const keys=Object.keys(P.cells).sort((a,b)=>(a.startsWith('(')-b.startsWith('('))||a.localeCompare(b));
  const order=keys.filter(k=>k.startsWith('(')).concat(keys.filter(k=>k.startsWith('~')),keys.filter(k=>!k.startsWith('(')&&!k.startsWith('~')));
  order.forEach((k,i)=>{if(physOn[k]===false)return;const a=P.cells[k];
    const un=k.startsWith('(');ctx.fillStyle=un?css('line'):colourFor(k,i);ctx.globalAlpha=un?.55:(k.startsWith('~')?.45:1);
    const r=un?1.3:(k.startsWith('~')?1.6:2.4);
    for(let j=0;j<a.length;j+=2){ctx.fillRect(10+(a[j]-x0)*s-r/2,10+(y1-a[j+1])*s-r/2,r,r)}});
  ctx.globalAlpha=1;
  $('#physinfo').textContent=`Die ${(x1-x0).toFixed(1)} × ${(y1-y0).toFixed(1)} µm. Each dot is one placed cell; fill and tap cells are omitted.`;}
function physLegend(){if(!P)return;const ul=$('#physlegend');const keys=Object.keys(P.counts).sort((a,b)=>P.counts[b]-P.counts[a]);
  ul.innerHTML='';keys.forEach((k,i)=>{const li=document.createElement('li');const id='pk'+i;
    const label=k.startsWith('~')?k.slice(1)+' (inferred)':k.startsWith('(')?k.slice(1,-1):k+' (named)';
    li.innerHTML=`<label for="${id}"><input type="checkbox" id="${id}" checked> <span class="sw" style="background:${k.startsWith('(')?css('line'):colourFor(k,i)}"></span>${label}: ${P.counts[k].toLocaleString()}</label>`;
    li.querySelector('input').onchange=e=>{physOn[k]=e.target.checked;drawPhys()};ul.appendChild(li)});
  if(P.not_found.length){const li=document.createElement('li');li.textContent='No cell found for: '+P.not_found.join(', ')+' (optimised away or renamed by synthesis)';ul.appendChild(li)}}
physLegend();
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
  case 'lane':return e.capable?`Cost engine, row ${e.eng} (${ENG(e.name)}): predicted ${e.tpred} cycles, cost ${e.cost}, calibration factor ${e.k}/64${e.qd?`, ${e.qd} queued`:''}.`:
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
    return `<tr class="${r.chosen?'win':(rej?'rej':'')}"><td>${ENG(r.name)}</td><td class="num">${cost}</td><td><span class="bar" style="width:${bw}px"></span></td><td class="why">${r.chosen?'chosen':(r.pending?'swept, waiting for select':(r.why||''))}</td></tr>`}).join('')||'<tr><td colspan="4" class="muted">No decision yet.</td></tr>'}
function renderTags(i){let b=sig('tag_busy',cyc);if(b==null){const t=lastOf('tag',i);b=t?t.busy_after:0}
  $('#tags').innerHTML=[0,1,2,3].map(t=>`<div class="tagc${b>>t&1?' busy':''}">tag ${t}<br>${b>>t&1?'busy':'free'}</div>`).join('')}
function hx(b){return b.map(x=>x.toString(16).padStart(2,'0')).join(' ')}
function renderSpi(i){const e=lastOf('spi',i);if(!e){$('#spi').textContent='No frame yet.';return}
  $('#spi').innerHTML=`<div>COPI: ${hx(e.bytes)}</div><div>CIPO: ${hx(e.cipo.slice(0,e.bytes.length))}</div><div class="muted">${describe(e)}</div>`}
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
      const e0=(BigInt(A[i])+v)%qq,e1=((BigInt(A[i])-v)%qq+qq)%qq;chk=(BigInt(Y0[i])===e0&&BigInt(Y1[i])===e1)?'✓ matches':'(outputs belong to an earlier input)'}
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
function stop(){if(timer){clearTimeout(timer);timer=null}const b=$('#b-play');b.setAttribute('aria-pressed','false');b.textContent='▶ Play'}
function step(){const n=tr.events.findIndex(e=>e.c>Math.round(cyc));if(n<0){stop();return}const target=tr.events[n].c;
  if(reduce){goto(target);timer=setTimeout(step,1500/speed);return}
  const from=cyc,t0=performance.now(),dur=Math.min(700,40+(target-from)*2)/speed;
  const anim=now=>{const f=Math.min(1,(now-t0)/dur);cyc=from+(target-from)*f;renderAll();
    if(f<1&&timer)requestAnimationFrame(anim);else if(timer){cyc=target;renderAll();timer=setTimeout(step,1400/speed)}};
  timer=setTimeout(()=>requestAnimationFrame(anim),0)}
$('#b-play').onclick=()=>{if(timer){stop();return}const b=$('#b-play');b.setAttribute('aria-pressed','true');b.textContent='⏸ Pause';step()};
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

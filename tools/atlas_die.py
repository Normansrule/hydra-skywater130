#!/usr/bin/env python3
"""
atlas_die.py -- the tile's real routed layout, and a gate-level recording
that lights it, for the Silicon Atlas die view (in the manner of Visual 6502).

    python3 tools/atlas_die.py layout RUN_DIR      docs/atlas/die.{json,bin}
    python3 tools/atlas_die.py gl RUN_DIR          docs/atlas/die-gl.{json,bin}

layout: reads the placed and routed DEF of one hardened run (RUN_DIR/final/def)
and the standard-cell LEF of the PDK the run used, and keeps every placed cell
(with the class and RTL instance tools/atlas_physical.py gives it), every
routed wire segment and via of every signal net, the power grid, and the pins.
Nothing is simplified or invented: the page draws these rectangles as they are,
with coordinates rounded to 0.02 um.

gl: runs one test of the tile's own cocotb suite on that run's HARDENED
netlist (as scripts/tile-gl.sh does), dumping every net of the netlist, and
keeps the value of every net in every cycle of one dispatch decision. A value
is sampled just before the next rising clock edge, the rule tools/atlas_traces.py
uses, so a unit-delay glitch between edges is never shown as a state. The run
must pass, and its pins must equal the Recorded RTL Trace of the same test
cycle for cycle over the window, or nothing is written. Label: Gate-Level Trace.

Both refuse a run whose netlist was not built from tt/tile/src/project.v.
"""
import bisect, gzip, hashlib, json, os, pathlib, re, shutil, struct, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import atlas_physical as ap                     # noqa: E402
import vcd                                      # noqa: E402

OUT = ROOT / "docs/atlas"
TILE = ROOT / "tt/tile"
BS = chr(92)
Q = 20                    # DEF units (nm) per stored unit: 0.02 um, so the die fits 16 bits
LAYERS = ["li1", "met1", "met2", "met3", "met4", "met5"]
# Default routing widths (um) of the sky130A technology LEF; the DEF's regular
# wires carry no width of their own.
WIDTH = {"li1": 0.17, "met1": 0.14, "met2": 0.14, "met3": 0.30, "met4": 0.30, "met5": 1.60}
# Via cut squares (um) and the layer a via's cut is drawn on (below -> above).
VIA = [("L1M1", "mcon", 0.17), ("M1M2", "via", 0.15), ("M2M3", "via2", 0.20),
       ("M3M4", "via3", 0.20), ("M4M5", "via4", 0.80)]
CLASSES = ["fill", "antenna", "flop", "logic", "buffer", "clock", "hold", "tie"]


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def find_pdk():
    for root in (os.environ.get("PDK_ROOT"), "/tmp/pdk", str(pathlib.Path.home() / "ttsetup/pdk"),
                 str(pathlib.Path.home() / ".ciel"), str(pathlib.Path.home() / ".volare")):
        if root and os.path.isdir(root):
            r = subprocess.run(["find", root, "-path", "*sky130A/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef"],
                               capture_output=True, text=True).stdout.split()
            if r:
                return pathlib.Path(r[0]).parents[4]
    raise SystemExit("atlas_die: sky130A standard-cell LEF not found; set PDK_ROOT")


def lef_sizes(path):
    sizes, cur = {}, None
    for line in open(path):
        t = line.split()
        if not t:
            continue
        if t[0] == "MACRO":
            cur = t[1]
        elif t[0] == "SIZE" and cur:
            sizes[cur] = (float(t[1]), float(t[3]))
        elif t[0] == "END" and len(t) > 1 and t[1] == cur:
            cur = None
    return sizes


# Inside a cell, the layers a mask shop would draw (GDS layer, datatype).
CELL_LAYERS = [("nwell", 64, 20), ("diff", 65, 20), ("tap", 65, 44), ("poly", 66, 20),
               ("licon", 66, 44), ("li1", 67, 20), ("mcon", 67, 44), ("met1", 68, 20)]
QC = 10                   # nm per stored unit inside a cell template: 0.01 um


def gds_cells(path, want):
    """Boundaries of the GDSII structures named in `want`, per (layer, datatype).
    A minimal stream reader: standard cells are flat, so BOUNDARY elements are
    all there is to read; anything else is counted and reported."""
    data = pathlib.Path(path).read_bytes()
    out, skipped = {}, {}
    i, name, el, layer, dt, xy, dbu_nm = 0, None, None, None, None, None, 1.0
    while i + 4 <= len(data):
        ln, rt = struct.unpack(">HB", data[i:i + 3])
        body = data[i + 4:i + ln]
        if ln < 4:
            break
        if rt == 0x03:                                     # UNITS: user, meters per dbu
            m = body[8:16]
            sign = -1 if m[0] & 0x80 else 1
            exp = (m[0] & 0x7F) - 64
            mant = int.from_bytes(m[1:], "big") / 2 ** 56
            dbu_nm = sign * mant * 16 ** exp * 1e9
        elif rt == 0x06:
            name = body.rstrip(b"\0").decode()
        elif rt == 0x07:
            name = None
        elif rt in (0x08, 0x09, 0x0A, 0x0B, 0x0C):
            el, width, ptype = rt, 0, 0
            if rt not in (0x08, 0x09) and name in want:
                kind = {0x09: "PATH", 0x0A: "SREF", 0x0B: "AREF", 0x0C: "TEXT"}[rt]
                skipped[kind] = skipped.get(kind, 0) + 1
        elif rt == 0x0D:
            layer = struct.unpack(">h", body)[0]
        elif rt == 0x0E:
            dt = struct.unpack(">h", body)[0]
        elif rt == 0x0F:
            width = struct.unpack(">i", body)[0] * dbu_nm
        elif rt == 0x21:
            ptype = struct.unpack(">h", body)[0]
        elif rt == 0x10:
            xy = struct.unpack(f">{len(body) // 4}i", body)
        elif rt == 0x11:
            if name in want and xy:
                pts = [(xy[k] * dbu_nm, xy[k + 1] * dbu_nm) for k in range(0, len(xy), 2)]
                if el == 0x08:
                    out.setdefault(name, []).append((layer, dt, pts))
                elif el == 0x09:                           # a path: one rectangle per segment
                    h = abs(width) / 2
                    e = h if ptype == 2 else 0
                    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
                        if x1 != x2 and y1 != y2:
                            skipped["oblique PATH"] = skipped.get("oblique PATH", 0) + 1
                            continue
                        if y1 == y2:
                            r = (min(x1, x2) - e, y1 - h, max(x1, x2) + e, y1 + h)
                        else:
                            r = (x1 - h, min(y1, y2) - e, x1 + h, max(y1, y2) + e)
                        out.setdefault(name, []).append(
                            (layer, dt, [(r[0], r[1]), (r[2], r[1]), (r[2], r[3]), (r[0], r[3])]))
            el = xy = None
        i += ln
    return out, skipped


def manhattan_rects(pts):
    """A Manhattan polygon as horizontal strips: one rectangle per span."""
    ys = sorted({y for _, y in pts})
    edges = [(pts[k], pts[(k + 1) % len(pts)]) for k in range(len(pts))]
    rects = []
    for ya, yb in zip(ys, ys[1:]):
        ym = (ya + yb) / 2
        xs = sorted(x1 for (x1, y1), (x2, y2) in edges if x1 == x2 and min(y1, y2) < ym < max(y1, y2))
        for k in range(0, len(xs) - 1, 2):
            rects.append((xs[k], ya, xs[k + 1], yb))
    return rects


def q(v_nm):
    return max(0, min(65535, int(round(v_nm / Q))))


def statements(lines):
    """DEF statements of a section: '- name ... ;' joined into one string."""
    buf = []
    for line in lines:
        s = line.strip()
        if not s:
            continue
        if s.startswith("-") and buf:
            yield " ".join(buf)
            buf = []
        buf.append(s)
        if s.endswith(";"):
            yield " ".join(buf)
            buf = []
    if buf:
        yield " ".join(buf)


def parse_routes(stmt, special):
    """Wire rectangles and vias of one NETS or SPECIALNETS statement.
    Returns (name, [(layer, x1, y1, x2, y2, half_width_nm, extend)], [(via, x, y)])."""
    tok = stmt.replace("(", " ( ").replace(")", " ) ").split()
    name = tok[1].replace(BS, "")
    wires, vias = [], []
    i, n = 2, len(tok)
    layer, hw, last = None, 0, None
    while i < n:
        t = tok[i]
        if t in ("ROUTED", "NEW", "FIXED", "COVER"):
            layer = tok[i + 1]
            i += 2
            last = None
            hw = WIDTH.get(layer, 0.14) * 500
            if special and i < n and re.fullmatch(r"\d+", tok[i]):
                hw = int(tok[i]) / 2
                i += 1
            continue
        if t == "+":
            if tok[i + 1] == "SHAPE":                  # a special wire's shape: same path
                i += 3
            elif tok[i + 1] in ("USE", "WEIGHT", "SOURCE", "PROPERTY"):
                layer = None
                i += 3
            else:
                i += 1
            continue
        if layer is None:
            i += 1
            continue
        if t == "(":
            j = tok.index(")", i)
            v = tok[i + 1:j]
            x = last[0] if v[0] == "*" else int(v[0])
            y = last[1] if v[1] == "*" else int(v[1])
            if last is not None and (x, y) != last:
                wires.append((layer, last[0], last[1], x, y, hw, not special))
            last = (x, y)
            i = j + 1
            continue
        if t == "RECT":
            j = tok.index(")", i)
            dx1, dy1, dx2, dy2 = (int(v) for v in tok[i + 2:j])
            wires.append((layer, last[0] + dx1, last[1] + dy1, last[0] + dx2, last[1] + dy2, -1, False))
            i = j + 1
            continue
        if t == "VIRTUAL" or t == "MASK":
            i += 2
            continue
        if t == ";":
            break
        # a via name at the current point
        if last is not None and re.match(r"(L1M1|M1M2|M2M3|M3M4|M4M5)", t):
            vias.append((t[:4], last[0], last[1]))
        i += 1
    return name, wires, vias


def rect(w):
    """(layer, x1, y1, x2, y2) of a wire: a centreline plus half width on every
    side, extended past its ends by the half width (DEF's default for regular
    wires), or a RECT patch as given."""
    layer, x1, y1, x2, y2, hw, ext = w
    if hw < 0:
        return layer, min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)
    e = hw if ext else 0
    if y1 == y2:
        return layer, min(x1, x2) - e, y1 - hw, max(x1, x2) + e, y1 + hw
    return layer, x1 - hw, min(y1, y2) - e, x1 + hw, max(y1, y2) + e


class Blob:
    """Named little-endian arrays packed into one gzip file; the table of
    contents goes in the JSON beside it."""
    def __init__(self):
        self.parts, self.toc, self.off = [], {}, 0

    def add(self, name, fmt, values, delta=False):
        """delta: store each value minus the one before it (modulo the type's
        range), for sorted columns; the reader sums them back."""
        if delta:
            mod = 1 << (8 * struct.calcsize(fmt))
            values = [(v - (values[i - 1] if i else 0)) % mod for i, v in enumerate(values)]
        b = struct.pack(f"<{len(values)}{fmt}", *values)
        self.toc[name] = {"type": fmt, "offset": self.off, "count": len(values), "delta": delta}
        self.parts.append(b)
        self.off += len(b)
        pad = (-self.off) % 4
        if pad:
            self.parts.append(b"\0" * pad)
            self.off += pad

    def write(self, path):
        data = gzip.compress(b"".join(self.parts), compresslevel=9, mtime=0)
        pathlib.Path(path).write_bytes(data)
        return len(data)


def check_run(run):
    f = run / "final"
    pnl = next((f / "pnl").glob("*.pnl.v"))
    proj = TILE / "src/project.v"
    r = subprocess.run([sys.executable, str(ROOT / "tools/netlist_matches.py"), str(pnl), str(proj)],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"atlas_die: {pnl} was not built from {proj}:\n{r.stdout}{r.stderr}")
    return f, pnl, r.stdout.strip()


# ---------------------------------------------------------------------------
def layout(run):
    f, pnl, matches = check_run(run)
    defp = next((f / "def").glob("*.def"))
    nlp = next((f / "nl").glob("*.nl.v"))
    pdk = find_pdk()
    lefp = pdk / "sky130A/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef"
    sizes = lef_sizes(lefp)

    # cells, attributed exactly as atlas_physical.py does
    derived = json.loads((OUT / "derived.json").read_text())
    inst_paths = {i["path"].split(".", 1)[1] for i in derived["builds"]["tile"]["instances"] if "." in i["path"]}
    inst_paths |= {p.rsplit(".", 1)[0] for p in list(inst_paths) if "." in p}
    die, comps = ap.parse_def(defp)
    cells = ap.parse_netlist(nlp)
    kinds = {i: ap.klass(c[0], i) for i, c in cells.items()}
    named = {i: ap.owner(c[1], inst_paths) for i, c in cells.items() if kinds[i] in ("flop", "logic")}
    flop_owner = {i: o for i, o in named.items() if kinds[i] == "flop"}
    cones = ap.cone_owners(cells, flop_owner, kinds)
    modules = sorted({m for m in named.values() if m} | {next(iter(c)) for c in cones.values()
                                                         if len(c) == 1 and None not in c})
    mid = {m: k + 1 for k, m in enumerate(modules)}            # 0 = no instance
    if len(modules) > 127:
        raise SystemExit("atlas_die: more than 127 RTL instances; widen the module field")
    orient = {}
    for line in open(defp):
        m = re.match(r"\s*-\s+(\S+)\s+\S+.*?\+\s+(?:PLACED|FIXED)\s+\(\s*-?\d+\s+-?\d+\s*\)\s+(\S+)", line)
        if m:
            orient[m.group(1).replace(BS, "")] = m.group(2)
        elif line.startswith("END COMPONENTS"):
            break
    # every used macro's own drawing, from the PDK's GDS
    used = sorted({c[0] for c in comps.values()})
    gdsp = pdk / "sky130A/libs.ref/sky130_fd_sc_hd/gds/sky130_fd_sc_hd.gds"
    shapes, skipped = gds_cells(gdsp, set(used))
    lmap = {(l, d): k for k, (_, l, d) in enumerate(CELL_LAYERS)}
    t_off, t_cnt, tr = [], [], {"x1": [], "y1": [], "x2": [], "y2": [], "layer": []}
    oblique = 0
    for mac in used:
        t_off.append(len(tr["layer"]))
        n0 = len(tr["layer"])
        for l, d, pts in shapes.get(mac, []):
            if (l, d) not in lmap:
                continue
            p = pts[:-1] if pts[0] == pts[-1] else pts
            if any(a[0] != b[0] and a[1] != b[1] for a, b in zip(p, p[1:] + p[:1])):
                oblique += 1
                continue
            for x1, y1, x2, y2 in manhattan_rects(p):
                for k, v in zip(("x1", "y1", "x2", "y2"), (x1, y1, x2, y2)):
                    tr[k].append(max(0, min(65535, int(round(v / QC)))))
                tr["layer"].append(lmap[(l, d)])
        t_cnt.append(len(tr["layer"]) - n0)
    macro_id = {m: k for k, m in enumerate(used)}
    heights = set()
    cx, cy, cw, ck, cm, cmac, cor = [], [], [], [], [], [], []
    ORI = {"N": 0, "FS": 1, "S": 2, "FN": 3, "W": 4, "E": 5, "FW": 6, "FE": 7}
    for inst, (macro, x, y) in sorted(comps.items(), key=lambda kv: (kv[1][2], kv[1][1])):
        w, h = sizes[macro]
        heights.add(h)
        cmac.append(macro_id[macro])
        cor.append(ORI[orient[inst]])
        k = ap.klass(macro, inst) or "fill"
        m = named.get(inst)
        code = mid[m] if m else 0
        if not m and k == "logic":
            c = cones.get(inst, set())
            if len(c) == 1 and None not in c:
                code = mid[next(iter(c))] | 0x80                # inferred from the flops it drives
        cx.append(q(x * 1000)); cy.append(q(y * 1000)); cw.append(q(w * 1000))
        ck.append(CLASSES.index(k)); cm.append(code)
    if len(heights) != 1:
        raise SystemExit(f"atlas_die: cells of more than one height: {sorted(heights)}")

    # nets: drivers' instance, wires and vias
    text = open(defp).read().split("\n")
    sec = {}
    for i, line in enumerate(text):
        m = re.match(r"(NETS|SPECIALNETS|PINS) (\d+) ;", line)
        if m:
            sec[m.group(1)] = i
        m = re.match(r"END (NETS|SPECIALNETS|PINS)", line)
        if m:
            sec["END " + m.group(1)] = i
    drv = {}
    for inst, (_, outs, _) in cells.items():
        for o in outs:
            drv[o] = inst
    names, net_mod = [], []
    wl = {l: [] for l in LAYERS}
    vl = {v[0]: [] for v in VIA}
    for st in statements(text[sec["NETS"] + 1:sec["END NETS"]]):
        name, wires, vias = parse_routes(st, False)
        n = len(names)
        names.append(name)
        d = drv.get(name)
        m = named.get(d) if d else None
        net_mod.append(mid[m] if m else 0)
        for w in wires:
            L, x1, y1, x2, y2 = rect(w)
            wl[L].append((n, q(x1), q(y1), q(x2), q(y2)))
        for v, x, y in vias:
            vl[v].append((n, q(x), q(y)))
    if len(names) > 65535:
        raise SystemExit("atlas_die: more than 65535 nets; widen the net field")
    power = []
    for st in statements(text[sec["SPECIALNETS"] + 1:sec["END SPECIALNETS"]]):
        name, wires, vias = parse_routes(st, True)
        p = 0 if "PWR" in name.upper() or name.upper().startswith("VDD") else 1
        for w in wires:
            L, x1, y1, x2, y2 = rect(w)
            power.append((p, LAYERS.index(L), q(x1), q(y1), q(x2), q(y2)))
    pins = []
    for st in statements(text[sec["PINS"] + 1:sec["END PINS"]]):
        nm = st.split()[1].replace(BS, "")
        lay = re.search(r"\+ LAYER (\S+) \( (-?\d+) (-?\d+) \) \( (-?\d+) (-?\d+) \)", st)
        pl = re.search(r"\+ (?:PLACED|FIXED) \( (-?\d+) (-?\d+) \) (\S+)", st)
        if lay and pl:
            x, y = int(pl.group(1)), int(pl.group(2))
            a, b, c, d = (int(lay.group(k)) for k in range(2, 6))
            pins.append({"name": nm, "layer": lay.group(1),
                         "rect": [q(x + min(a, c)), q(y + min(b, d)), q(x + max(a, c)), q(y + max(b, d))]})

    blob = Blob()
    blob.add("cell_x", "H", cx, delta=True)
    blob.add("cell_y", "H", cy, delta=True)
    blob.add("cell_w", "H", cw)
    blob.add("cell_class", "B", ck)
    blob.add("cell_module", "B", cm)
    blob.add("cell_macro", "H", cmac)
    blob.add("cell_orient", "B", cor)
    blob.add("tpl_offset", "I", t_off)
    blob.add("tpl_count", "H", t_cnt)
    for k in ("x1", "y1", "x2", "y2"):
        blob.add(f"tpl_{k}", "H", tr[k])
    blob.add("tpl_layer", "B", tr["layer"])
    blob.add("net_module", "B", net_mod)
    counts = {}
    for L in LAYERS:
        segs = sorted(wl[L])
        counts[L] = len(segs)
        if segs:
            # a rectangle as its lower-left corner and its size: sizes repeat
            # (track widths), so they compress to almost nothing
            blob.add(f"{L}_net", "H", [s[0] for s in segs], delta=True)
            blob.add(f"{L}_x", "H", [s[1] for s in segs], delta=True)
            blob.add(f"{L}_y", "H", [s[2] for s in segs], delta=True)
            blob.add(f"{L}_w", "H", [s[3] - s[1] for s in segs])
            blob.add(f"{L}_h", "H", [s[4] - s[2] for s in segs])
    for v, cut, size in VIA:
        pts = sorted(vl[v])
        counts[cut] = len(pts)
        if pts:
            blob.add(f"{cut}_net", "H", [p[0] for p in pts], delta=True)
            blob.add(f"{cut}_x", "H", [p[1] for p in pts], delta=True)
            blob.add(f"{cut}_y", "H", [p[2] for p in pts], delta=True)
    power.sort()
    blob.add("power_net", "B", [p[0] for p in power])
    blob.add("power_layer", "B", [p[1] for p in power])
    blob.add("power_x", "H", [p[2] for p in power], delta=True)
    blob.add("power_y", "H", [p[3] for p in power], delta=True)
    blob.add("power_w", "H", [p[4] - p[2] for p in power])
    blob.add("power_h", "H", [p[5] - p[3] for p in power])
    namestr = "\n".join(names).encode()
    blob.parts.append(namestr)
    blob.toc["net_names"] = {"type": "utf8", "offset": blob.off, "count": len(namestr)}
    blob.off += len(namestr)
    binp = OUT / "die.bin"
    size = blob.write(binp)
    meta = {
        "_comment": "Generated by tools/atlas_die.py layout. Every rectangle is from the run's DEF; "
                    "cells sized from the PDK's LEF; cells attributed as tools/atlas_physical.py does.",
        "run": {"dir": str(run), "def": defp.name, "def_sha256": sha(defp), "netlist_sha256": sha(pnl),
                "lef": str(lefp.relative_to(pdk)), "lef_sha256": sha(lefp), "matches_project_v": matches},
        "unit_um": Q / 1000, "die_um": die, "cell_h_um": heights.pop(),
        "classes": CLASSES, "modules": modules, "layers": LAYERS,
        "macros": used, "cell_layers": [n for n, _, _ in CELL_LAYERS], "template_unit_um": QC / 1000,
        "gds": {"file": str(gdsp.relative_to(pdk)), "sha256": sha(gdsp), "template_rects": len(tr["layer"]),
                "oblique_polygons_skipped": oblique, "non_boundary_elements": skipped},
        "orientations": list(ORI),
        "widths_um": WIDTH, "vias": [{"name": v, "cut": c, "size_um": s} for v, c, s in VIA],
        "counts": {"cells": len(cx), "nets": len(names), "power_rects": len(power), **counts},
        "pins": pins, "bin": {"file": binp.name, "sha256": sha(binp), "bytes": size, "toc": blob.toc},
    }
    (OUT / "die.json").write_text(json.dumps(meta, indent=1, sort_keys=True) + "\n")
    print(f"atlas_die: {len(cx)} cells, {len(names)} nets, "
          + ", ".join(f"{counts[k]} {k}" for k in counts) + f", {len(power)} power rectangles; "
          f"wrote docs/atlas/die.json and die.bin ({size // 1024} KiB)")


# ---------------------------------------------------------------------------
def gl(run, trace_id="crossover", decision=2, before=8, after=6):
    f, pnl, matches = check_run(run)
    meta = json.loads((OUT / "die.json").read_text())
    if meta["run"]["netlist_sha256"] != sha(pnl):
        raise SystemExit("atlas_die: die.json is from another run; run `atlas_die.py layout` first")
    rtl = json.loads((OUT / f"traces/{trace_id}.json").read_text())
    test = rtl["test"].split("::")[1]
    module = pathlib.Path(rtl["test"].split("::")[0]).stem
    gos = [e["c"] for e in rtl["events"] if e["k"] == "go" and e.get("accepted")]
    tags = [e["c"] for e in rtl["events"] if e["k"] == "tag"]
    c0, c1 = gos[decision - 1] - before, tags[decision - 1] + after

    pdk = find_pdk()
    tmp = tempfile.mkdtemp(prefix="atlas_die_")
    try:
        shutil.copytree(TILE / "test", f"{tmp}/test")
        shutil.copy(pnl, f"{tmp}/test/gate_level_netlist.v")
        tb = pathlib.Path(f"{tmp}/test/tb.v")
        src = tb.read_text()
        if "$dumpvars(0, tb);" not in src:
            raise SystemExit("atlas_die: tb.v no longer has `$dumpvars(0, tb);`")
        # The netlist's own nets only: the testbench at depth 1 and the
        # design's scope at depth 1, not the inside of every cell model.
        tb.write_text(src.replace("$dumpvars(0, tb);", "$dumpvars(1, tb);\n    $dumpvars(1, tb.user_project);"))
        env = dict(os.environ, PDK_ROOT=str(pdk))
        cmd = (f"make -s SRC_DIR={TILE / 'src'} COCOTB_TEST_MODULES={module} "
               f"COCOTB_TEST_FILTER='{test}$' GATES=yes")
        r = subprocess.run(cmd, cwd=f"{tmp}/test", shell=True, capture_output=True, text=True,
                           env=env, executable="/bin/bash", timeout=7200)
        log = r.stdout + r.stderr
        if r.returncode or not re.search(r"TESTS=1 PASS=1 FAIL=0", log):
            raise SystemExit(f"atlas_die: {module}.{test} did not pass on the netlist; refusing.\n{log[-3000:]}")
        sigs, ts, _ = vcd.read(f"{tmp}/test/tb.vcd", [r"tb\.clk", r"tb\.user_project\..*"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    edges = [t for t, v in sigs["tb.clk"]["changes"] if v == "1"]
    period = edges[1] - edges[0]
    ends = edges[1:] + [edges[-1] + period]
    pre = "tb.user_project."
    names = meta_names(meta)
    index = {n: k for k, n in enumerate(names)}
    # VCD names -> DEF nets, bit by bit (ports are vectors in the netlist)
    bits = {}
    for full, s in sigs.items():
        if not full.startswith(pre):
            continue
        base = full[len(pre):].replace(BS, "")
        if s["width"] == 1:
            if base in index:
                bits[index[base]] = (s, 0)
        else:
            for b in range(s["width"]):
                nm = f"{base}[{b}]"
                if nm in index:
                    bits[index[nm]] = (s, s["width"] - 1 - b)
    code = {"0": 0, "1": 1, "x": 2, "z": 3}

    for s in sigs.values():
        s["t"] = [t for t, _ in s["changes"]]

    def settled(s, pos, c):
        i = bisect.bisect_left(s["t"], ends[c]) - 1
        return code[s["changes"][i][1][pos]] if i >= 0 else 2

    nn = len(names)
    state0 = [2] * nn
    ev_net, ev_val, per = [], [], []
    for n, (s, pos) in bits.items():
        state0[n] = settled(s, pos, c0)
    cur = list(state0)
    for c in range(c0 + 1, c1 + 1):
        k = 0
        for n, (s, pos) in bits.items():
            v = settled(s, pos, c)
            if v != cur[n]:
                ev_net.append(n); ev_val.append(v); cur[n] = v; k += 1
        per.append(k)
    # activity over the whole test: settled changes per net
    act = [0] * nn
    for n, (s, pos) in bits.items():
        # a cycle's value is its last change before the cycle ends, so only
        # the cycles in which this net changed can differ from the one before
        cyc = sorted({bisect.bisect_right(ends, t) for t in s["t"] if t < ends[-1]})
        prev = None
        for c in [0] + cyc:
            v = settled(s, pos, min(c, len(ends) - 1))
            if prev is not None and v != prev:
                act[n] += 1
            prev = v
        act[n] = min(act[n], 65535)
    # the pins must be the RTL trace's, cycle for cycle, over the window
    def rtl_at(name, c):
        ser = rtl["signals"][name]["v"]
        i = bisect.bisect_right([x for x, _ in ser], c) - 1
        return ser[i][1]
    bad = []
    for pin, w in (("uo_out", 8), ("uio_out", 8)):
        for c in range(c0, c1 + 1):
            want = rtl_at(pin, c)
            s = sigs.get(pre + pin)
            got = settled_word(s, ends, c, w)
            if want != got:
                bad.append((pin, c, want, got))
    if bad:
        raise SystemExit(f"atlas_die: the netlist's pins differ from the RTL trace: {bad[:6]}")
    blob = Blob()
    blob.add("state0", "B", state0)
    blob.add("per_cycle", "H", per)
    blob.add("ev_net", "H", ev_net)
    blob.add("ev_val", "B", ev_val)
    blob.add("activity", "H", act)
    binp = OUT / "die-gl.bin"
    size = blob.write(binp)
    passed = re.search(r"\*\* (\S+)\s+PASS\s+([\d.]+)", log)
    out = {
        "_comment": "Generated by tools/atlas_die.py gl. Net values sampled just before the next rising edge.",
        "label": "Gate-Level Trace", "trace": trace_id, "decision": decision,
        "test": rtl["test"], "result": "PASS",
        "command": f"cd tt/tile/test && make COCOTB_TEST_MODULES={module} COCOTB_TEST_FILTER={test} GATES=yes",
        "sim_time_ns": float(passed.group(2)) if passed else None,
        "netlist_sha256": sha(pnl), "project_v_sha256": sha(TILE / "src/project.v"),
        "test_sha256": sha(TILE / f"test/{module}.py"), "tb_sha256": sha(TILE / "test/tb.v"),
        "cycles": [c0, c1], "clock_ns": period * __import__("atlas_traces").timescale_ns(ts),
        "nets_recorded": len(bits), "nets_in_layout": nn, "events": len(ev_net),
        "pins_match_rtl": f"uo_out and uio_out equal {trace_id}.json in every cycle {c0}..{c1}",
        "bin": {"file": binp.name, "sha256": sha(binp), "bytes": size, "toc": blob.toc},
    }
    (OUT / "die-gl.json").write_text(json.dumps(out, indent=1, sort_keys=True) + "\n")
    print(f"atlas_die: {len(bits)} of {nn} nets recorded on the netlist, cycles {c0}..{c1}, "
          f"{len(ev_net)} value changes; pins equal the RTL trace; wrote die-gl.json and die-gl.bin ({size // 1024} KiB)")


def settled_word(s, ends, c, w):
    ch = s["changes"]
    i = bisect.bisect_left(s["t"], ends[c]) - 1
    v = ch[i][1] if i >= 0 else None
    iv = vcd.as_int(v)
    return "x" if iv is None else format(iv, "x")


def meta_names(meta):
    raw = gzip.decompress((OUT / meta["bin"]["file"]).read_bytes())
    e = meta["bin"]["toc"]["net_names"]
    return raw[e["offset"]:e["offset"] + e["count"]].decode().split("\n")


def main():
    a = sys.argv[1:]
    if len(a) < 2 or a[0] not in ("layout", "gl"):
        raise SystemExit(__doc__)
    run = pathlib.Path(a[1]).expanduser()
    (layout if a[0] == "layout" else gl)(run)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
atlas_tile.py -- the Tiny Tapeout tile's pins and registers, read from its RTL.

Nothing here is typed in. The pin table comes from tt/tile/info.yaml (what
the shuttle sees) and is checked against the wrapper's own assignments in
tt/tile/src/tt_um_hydra_mom.sv; the register map comes from the decode in
tt/tile/src/rtl/hydra_tt_regs.sv (the address constants, reg_len(),
writable() and the read multiplexer), with the descriptions taken from that
file's own MAP comment and refused if the comment disagrees with the decode.

    python3 tools/atlas_tile.py         print both tables (a check, writes nothing)
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TILE = ROOT / "tt/tile"


def _concat(expr):
    """The parts of a {a, b, c} concatenation, most significant first."""
    body = expr.strip()
    assert body.startswith("{") and body.endswith("}"), expr
    parts, depth, cur = [], 0, ""
    for ch in body[1:-1]:
        if ch in "{([":
            depth += 1
        elif ch in "})]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip()); cur = ""
        else:
            cur += ch
    parts.append(cur.strip())
    return parts


def _width(part, widths):
    m = re.fullmatch(r"(\d+)'[bdh][0-9a-fA-F_]+", part)
    if m:
        return int(m.group(1))
    m = re.fullmatch(r"[|&^~]*(\w+)\[(\d+):(\d+)\]", part)
    if m:
        return int(m.group(2)) - int(m.group(3)) + 1
    m = re.fullmatch(r"[|&^]\w+", part)
    if m:
        return 1
    name = re.sub(r"[~!]", "", part)
    return widths.get(name, 1)


PKG_WIDTHS = {"COST_W": 32, "WD_W": 128, "EPARAM_W": 43}


def _pkg_widths():
    """The width parameters, from the tile's own package."""
    pkg = (TILE / "src/rtl/mom_pkg.sv").read_text()
    out = {}
    for n in PKG_WIDTHS:
        m = re.search(rf"localparam int unsigned {n}\s*=\s*(\d+);", pkg)
        out[n] = int(m.group(1))
    return out


def _decl_widths(src):
    for n, v in _pkg_widths().items():
        src = src.replace(f"[{n}-1:0]", f"[{v - 1}:0]")
    w = {}
    for m in re.finditer(r"(?:logic|wire|reg)\s*(?:\[(\d+):(\d+)\])?\s+([\w\s,]+?);", src):
        width = int(m.group(1)) - int(m.group(2)) + 1 if m.group(1) else 1
        for n in m.group(3).split(","):
            n = n.strip()
            if re.fullmatch(r"\w+", n):
                w[n] = width
    for m in re.finditer(r"(?:input|output)\s+(?:wire|logic)?\s*(?:\[(\d+):(\d+)\])?\s*(\w+)", src):
        w[m.group(3)] = int(m.group(1)) - int(m.group(2)) + 1 if m.group(1) else 1
    return w


def bit_fields(expr, src):
    """[(name, msb, lsb)] for a concatenation, in source order."""
    widths = _decl_widths(src)
    parts = _concat(expr)
    total = sum(_width(p, widths) for p in parts)
    out, hi = [], total - 1
    for p in parts:
        w = _width(p, widths)
        out.append((p, hi, hi - w + 1))
        hi -= w
    return out, total


def pins():
    import yaml
    info = yaml.safe_load((TILE / "info.yaml").read_text())
    src = (TILE / "src/tt_um_hydra_mom.sv").read_text()
    out = []
    uo = re.search(r"assign uo_out\s*=\s*(\{[^;]*\});", src).group(1)
    uio = re.search(r"assign uio_out\s*=\s*(\{[^;]*\});", src).group(1)
    oe = re.search(r"assign uio_oe\s*=\s*([^;]*);", src).group(1).strip()
    fu, wu = bit_fields(uo, src)
    fio, wio = bit_fields(uio, src)
    if wu != 8 or wio != 8:
        raise SystemExit(f"atlas_tile: uo_out is {wu} bits, uio_out {wio}")
    drive = {}
    for name, hi, lo in fu:
        for b in range(lo, hi + 1):
            drive[f"uo[{b}]"] = name if hi == lo else f"{name}[{b - lo}]"
    for name, hi, lo in fio:
        for b in range(lo, hi + 1):
            drive[f"uio[{b}]"] = name if hi == lo else f"{name}[{b - lo}]"
    spi = re.search(r"\.sck_i\((ui_in\[\d\])\),\s*\.copi_i\((ui_in\[\d\])\),\s*\.csn_i\((ui_in\[\d\])\)", src)
    used_in = {spi.group(1).replace("ui_in", "ui"): "sck_i", spi.group(2).replace("ui_in", "ui"): "copi_i",
               spi.group(3).replace("ui_in", "ui"): "csn_i"}
    for group, n, direction in (("ui", 8, "input"), ("uo", 8, "output"), ("uio", 8, "output" if oe == "8'hFF" else "?")):
        for b in range(n):
            key = f"{group}[{b}]"
            desc = info["pinout"].get(key, "")
            rtl = drive.get(key) if group != "ui" else used_in.get(key)
            out.append({"pin": key, "dir": direction, "desc": desc, "rtl": rtl or "unused"})
    # cross-check: a pin the RTL drives must not be described as unused, and
    # an input the SPI uses must be described
    bad = [p for p in out if p["rtl"] != "unused" and p["desc"].strip().lower() == "unused"]
    bad += [p for p in out if p["dir"] == "input" and p["rtl"] == "unused" and p["desc"].strip().lower() != "unused"]
    if bad:
        raise SystemExit(f"atlas_tile: info.yaml and the wrapper disagree: {bad}")
    p = info["project"]
    return {"pins": out, "clock_hz": p["clock_hz"], "tiles": p["tiles"], "top": p["top_module"],
            "uio_oe": oe, "title": p["title"], "author": p["author"]}


def registers():
    src = (TILE / "src/rtl/hydra_tt_regs.sv").read_text()
    addr = {n: int(v, 16) for n, v in re.findall(r"(A_\w+)\s*=\s*7'h([0-9A-Fa-f]+)", src)}
    lens = {n: int(v) for n, v in re.findall(r"(A_\w+):\s*reg_len\s*=\s*5'd(\d+);", src)}
    wfun = re.search(r"writable\s*=\s*(.*?);", src, re.S).group(1)
    writable = set(re.findall(r"a == (A_\w+)", wfun))
    rmux = re.search(r"case \(cmd_addr\)\s*\n(\s*A_ID:\s*rval.*?)endcase", src, re.S).group(1)
    readable = set(re.findall(r"(A_\w+):\s*rval", rmux))
    # descriptions from the MAP comment, checked against the decode
    mp = re.search(r"\* MAP\s+len\s+access.*?\n \* =+\n(.*?)\n \* =+", src, re.S).group(1)
    docs, cur = {}, None
    for line in mp.splitlines():
        m = re.match(r"\s*\*\s+0x([0-9A-F]{2}) (\S+)\s+(\d+)?\s*(RO|RW|WO)?\s*(.*)", line)
        if m:
            cur = int(m.group(1), 16)
            docs[cur] = {"name": m.group(2), "len": int(m.group(3)) if m.group(3) else 0,
                         "access": m.group(4) or "", "desc": m.group(5).strip()}
        elif line.split("*", 1)[-1].split()[:1] == ["other"]:
            cur = None
        elif cur is not None and line.strip(" *"):
            docs[cur]["desc"] += " " + line.strip(" *").strip()
    regs, problems = [], []
    for n, a in sorted(addr.items(), key=lambda kv: kv[1]):
        acc = ("R" if n in readable else "") + ("W" if n in writable else "")
        acc = {"R": "RO", "W": "WO", "RW": "RW"}.get(acc, "--")
        d = docs.get(a, {})
        if d.get("len") != lens.get(n, 0):
            problems.append(f"{n}: comment says {d.get('len')} bytes, reg_len says {lens.get(n)}")
        if d.get("access") != acc:
            problems.append(f"{n}: comment says {d.get('access')}, decode says {acc}")
        regs.append({"addr": a, "name": n[2:], "len": lens.get(n, 0), "access": acc,
                     "desc": d.get("desc", ""), "read_value": None})
    if problems:
        raise SystemExit("atlas_tile: the register comment disagrees with the decode:\n  " + "\n  ".join(problems))
    # field layouts of STATUS and RESULT from the RTL concatenations
    st = re.search(r"wire \[15:0\] status_w\s*=\s*(\{.*?\});", src, re.S).group(1)
    sf, _ = bit_fields(st, src)
    res = re.search(r"A_RESULT:\s*rval\s*=\s*\{\{\(WD_W-48\)\{1'b0\}\},\s*(.*?)\};", src, re.S).group(1)
    rf, rw = bit_fields("{" + res + "}", src.replace("r_margin;", "r_margin;"))
    return {"registers": regs, "status": [{"name": n, "msb": h, "lsb": l} for n, h, l in sf],
            "result": [{"name": n, "msb": h, "lsb": l} for n, h, l in rf], "result_bits": rw,
            "frame": "byte 0 = {rw, addr[6:0]} (rw = 1 reads); bytes 1..N data, most significant first; "
                     "a write commits when CSn rises, only if exactly LEN data bytes arrived"}


def main():
    p = pins()
    for x in p["pins"]:
        print(f"  {x['pin']:8s} {x['dir']:6s} {x['rtl']:22s} {x['desc']}")
    r = registers()
    for x in r["registers"]:
        print(f"  0x{x['addr']:02X} {x['name']:8s} {x['len']:2d} {x['access']}  {x['desc']}")
    print("  STATUS:", ", ".join(f"{f['name']}[{f['msb']}:{f['lsb']}]" for f in r["status"]))
    print("  RESULT:", ", ".join(f"{f['name']}[{f['msb']}:{f['lsb']}]" for f in r["result"]), r["result_bits"])


if __name__ == "__main__":
    main()

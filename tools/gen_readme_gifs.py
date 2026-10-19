#!/usr/bin/env python3
"""
gen_readme_gifs.py -- short README previews, drawn from recorded traces.

A README cannot run the atlas player, so it shows a few seconds of it as an
animated GIF and links to the page. Every frame is drawn from a recorded
trace in docs/atlas/traces (a passing test's value change dump); nothing is
typed in. Each GIF is a fixed loop of a handful of frames, long holds, no
flashing, and its last frame is complete on its own.

  demo_dispatch(.dark).gif  (both repositories) test_roofline_crossover on the tile: the 8x8x8
                            multiply costed on every engine row, the refused
                            engines, the winner, the tag and the calibration
  demo_array(.dark).gif     make tpu: the 4x4 systolic array on a 4x4x64 job,
                            operands moving in from two edges

    python3 tools/gen_readme_gifs.py          write docs/img/demo_*.gif
    python3 tools/gen_readme_gifs.py --check  fail if a GIF is stale
"""
import io, json, pathlib, sys
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import atlas_theme as T  # noqa: E402

OUT = ROOT / "docs/img"
TR = ROOT / "docs/atlas/traces"
FONTS = ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]
CHECK = "--check" in sys.argv
STALE = []
NAME = {"ENG_CPU": "CPU", "ENG_SIMD": "Vector unit", "ENG_TPU": "Systolic array", "ENG_NTT": "Butterflies",
        "ENG_CRYPTO": "Crypto slot"}


def font(i, size):
    return ImageFont.truetype(FONTS[i], size)


def save(name, frames, durations, dirs=None):
    buf = io.BytesIO()
    frames[0].save(buf, format="GIF", save_all=True, append_images=frames[1:], duration=durations,
                   loop=0, optimize=False, disposal=1)
    data = buf.getvalue()
    for d in dirs or [OUT]:
        f = d / name
        if CHECK:
            if not f.exists() or f.read_bytes() != data:
                STALE.append(str(f.relative_to(ROOT)))
            continue
        f.write_bytes(data)


MEDIA = ROOT / "docs/site/media"


def video(name, frames, durations, captions, alt, poster=-1):
    """The same frames as a WebM with WebVTT captions and a poster, for the
    site's <video controls> (pausable and seekable, unlike a GIF). A small
    manifest records the hash of the frames, timings and captions; --check
    compares that, because encoders are not byte-reproducible across versions."""
    import hashlib, subprocess, tempfile
    h = hashlib.sha256()
    for im, d, c in zip(frames, durations, captions):
        h.update(im.convert("RGB").tobytes()); h.update(str(d).encode()); h.update(c.encode())
    man = {"frames": len(frames), "sha256": h.hexdigest(), "alt": alt, "poster": poster}
    mf = MEDIA / f"{name}.json"
    if CHECK:
        if not mf.exists() or json.loads(mf.read_text()).get("sha256") != man["sha256"] or \
                not (MEDIA / f"{name}.webm").exists():
            STALE.append(str(mf.relative_to(ROOT)))
        return
    if mf.exists() and json.loads(mf.read_text()) == man and (MEDIA / f"{name}.webm").exists():
        return                          # same frames: keep the film as it is (encoders differ between runs)
    MEDIA.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        lst = []
        for i, (im, d) in enumerate(zip(frames, durations)):
            f = f"{tmp}/f{i:03d}.png"
            im.convert("RGB").save(f)
            lst.append(f"file '{f}'\nduration {d / 1000:.3f}")
        lst.append(f"file '{tmp}/f{len(frames) - 1:03d}.png'")
        (pathlib.Path(tmp) / "list.txt").write_text("\n".join(lst) + "\n")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", f"{tmp}/list.txt",
                        "-vf", "fps=10,format=yuv420p", "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "34",
                        "-row-mt", "1", str(MEDIA / f"{name}.webm")], check=True)
    frames[poster].convert("RGB").save(MEDIA / f"{name}.poster.png", optimize=True)
    t, cues = 0, ["WEBVTT", ""]
    for i, (d, c) in enumerate(zip(durations, captions)):
        a, b = t / 1000, (t + d) / 1000
        cues += [str(i + 1), f"00:{int(a // 60):02d}:{a % 60:06.3f} --> 00:{int(b // 60):02d}:{b % 60:06.3f}", c, ""]
        t += d
    (MEDIA / f"{name}.vtt").write_text("\n".join(cues))
    mf.write_text(json.dumps(man, indent=1) + "\n")


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


# ---------------------------------------------------------------------------
def dispatch(mode):
    p = T.LIGHT if mode == "light" else T.DARK
    tr = json.loads((TR / "crossover.json").read_text())
    ev = tr["events"]
    sel = [e for e in ev if e["k"] == "select"][1]                 # the 8x8x8 decision
    lanes = [e for e in ev if e["k"] == "lane" and sel["c"] - 12 <= e["c"] <= sel["c"]]
    desc = [e for e in ev if e["k"] == "desc"][1]
    tag = next(e for e in ev if e["k"] == "tag" and e["c"] >= sel["c"])
    cal = next(e for e in ev if e["k"] == "cal" and e["c"] >= sel["c"])
    W, H = 880, 360
    f_t, f_s, f_m, f_b = font(2, 20), font(0, 15), font(1, 14), font(2, 15)
    rows = sel["rows"]
    maxc = max(r["cost"] for r in rows if r["why"] != "cannot do this operation or data type")

    def frame(step):
        im = Image.new("RGB", (W, H), rgb(p["surface"]))
        d = ImageDraw.Draw(im)
        d.rounded_rectangle([1, 1, W - 2, H - 2], 14, outline=rgb(p["line"]), width=2)
        d.text((24, 18), "One decision on the Tiny Tapeout tile", font=f_t, fill=rgb(p["ink"]))
        d.text((24, 46), f"Recorded RTL trace · {tr['test'].split('::')[1]} · tile {tr['tile_commit'][:7]} · PASS",
               font=f_m, fill=rgb(p["dim"]))
        d.text((24, 76), f"{desc['op'][4:]} {desc['dtype'][3:]} {desc['m']}×{desc['n']}×{desc['kk']}, "
               f"{desc['bytes']} bytes: one cost engine walks every engine row, two cycles each",
               font=f_s, fill=rgb(p["ink2"]))
        y0 = 112
        for i, r in enumerate(rows):
            y = y0 + i * 34
            shown = i < step
            name = NAME.get(r["name"], r["name"])
            d.text((24, y + 4), name, font=f_b if shown and r["chosen"] and step > len(rows) else f_s,
                   fill=rgb(p["ink"] if shown else p["dim"]))
            if not shown:
                continue
            if r["why"] == "cannot do this operation or data type":
                d.text((200, y + 4), "✕ cannot do GEMM on INT8: refused before any cost", font=f_s, fill=rgb(p["danger"]))
                continue
            bw = int(380 * r["cost"] / maxc)
            win = r["chosen"] and step > len(rows)
            d.rounded_rectangle([200, y + 4, 200 + max(bw, 4), y + 22], 4,
                                fill=rgb(p["control"] if win else p["control_t"]), outline=rgb(p["control"]))
            d.text((210 + bw, y + 4), f"cost {r['cost']}" + ("  ✓ chosen" if win else ""), font=f_m,
                   fill=rgb(p["ink"]))
        if step > len(rows):
            d.text((24, 290), f"Dispatched with tag {tag['tag']}, margin {sel['margin']} over the runner-up.",
                   font=f_s, fill=rgb(p["ink"]))
        if step > len(rows) + 1:
            d.text((24, 316), f"On completion: measured {cal['meas']} cycles against {cal['pred']} predicted, "
                   f"so the factor moves {cal['k_cur']} → {cal['k_next']} (64 = exact).", font=f_s, fill=rgb(p["memory"]))
        return im.convert("P", palette=Image.ADAPTIVE, colors=64)

    n = len(rows)
    frames = [frame(s) for s in range(0, n + 3)]
    durs = [900] + [700] * n + [1600, 3600]
    if mode == "light":
        caps = [f"A {desc['op'][4:]} {desc['dtype'][3:]} {desc['m']}x{desc['n']}x{desc['kk']} descriptor arrives."]
        for r in rows:
            nm = NAME.get(r["name"], r["name"])
            caps.append(f"{nm}: refused, it cannot do this operation or data type." if r["why"] ==
                        "cannot do this operation or data type" else f"{nm}: cost {r['cost']}.")
        win = next(r for r in rows if r["chosen"])
        caps.append(f"{NAME.get(win['name'], win['name'])} wins: tag {tag['tag']}, margin {sel['margin']}.")
        caps.append(f"Completion: {cal['meas']} cycles measured against {cal['pred']} predicted; "
                    f"the factor moves {cal['k_cur']} to {cal['k_next']}.")
        video("dispatch", frames, durs, caps, "One decision on the tile, replayed from test_roofline_crossover")
    save(f"demo_dispatch{'.dark' if mode == 'dark' else ''}.gif", frames, durs, [OUT, ROOT / "tt/tile/docs/img"])


def array(mode):
    p = T.LIGHT if mode == "light" else T.DARK
    tr = json.loads((TR / "tpu.json").read_text())
    S = tr["signals"]

    def at(name, c):
        v = None
        for cc, x in S.get(name, {"v": []})["v"]:
            if cc > c:
                break
            v = x
        return None if v in (None, "x") else int(v, 16)

    def sg(v, w):
        return None if v is None else (v - (1 << w) if v >= 1 << (w - 1) else v)
    states = tr["meta"]["states"]["names"]
    W, H = 720, 440
    f_t, f_s, f_m = font(2, 19), font(0, 14), font(1, 13)
    # frames: closely through the skewed start, then every 16 cycles to done
    cyc = list(range(0, 40, 4)) + list(range(40, tr["cycles"], 16)) + [tr["cycles"] - 1]
    frames = []
    for c in cyc:
        im = Image.new("RGB", (W, H), rgb(p["surface"]))
        d = ImageDraw.Draw(im)
        d.rounded_rectangle([1, 1, W - 2, H - 2], 14, outline=rgb(p["line"]), width=2)
        st = states[at("dut.u_ctrl.st_q", c) or 0]
        d.text((22, 16), "The 4×4 INT8 systolic array, 4×4×64 multiply", font=f_t, fill=rgb(p["ink"]))
        d.text((22, 42), f"Recorded RTL trace · make tpu · cycle {c} of {tr['cycles'] - 1} · {st[2:]}",
               font=f_m, fill=rgb(p["dim"]))
        d.text((22, 64), "A enters from the west, B from the north; each processing element keeps its sum",
               font=f_s, fill=rgb(p["ink2"]))
        for r in range(4):
            for q in range(4):
                pre = f"dut.u_array.g_row[{r}].g_col[{q}].u_pe."
                a, b = sg(at(pre + "a_in", c), 8), sg(at(pre + "b_in", c), 8)
                acc = sg(at(pre + "acc_q", c), 32)
                x, y = 150 + q * 136, 96 + r * 82
                on = bool(a) and bool(b) and at("dut.u_ctrl.arr_en", c)
                d.rounded_rectangle([x, y, x + 124, y + 70], 9, fill=rgb(p["compute_t"] if on else p["raised"]),
                                    outline=rgb(p["compute"] if on else p["line"]), width=2)
                d.text((x + 10, y + 8), f"acc {acc}", font=f_m, fill=rgb(p["ink"]))
                d.text((x + 10, y + 30), f"a {a}  b {b}", font=f_m, fill=rgb(p["ink2"]))
                d.text((x + 10, y + 50), f"PE({r},{q})", font=f_m, fill=rgb(p["dim"]))
        for r in range(4):
            d.text((60, 120 + r * 82), "A →", font=f_s, fill=rgb(p["signal"]))
        for q in range(4):
            d.text((190 + q * 136, 80), "B ↓", font=f_s, fill=rgb(p["signal"]))
        frames.append(im.convert("P", palette=Image.ADAPTIVE, colors=64))
    durs = [500] * (len(frames) - 1) + [3000]
    if mode == "light":
        caps = [f"Cycle {c}: controller {states[at('dut.u_ctrl.st_q', c) or 0][2:]}." for c in cyc]
        video("array", frames, durs, caps, "The 4x4 systolic array on a 4x4x64 job, replayed from make tpu",
              poster=min(range(len(cyc)), key=lambda i: abs(cyc[i] - 72)))
    save(f"demo_array{'.dark' if mode == 'dark' else ''}.gif", frames, durs)


def main():
    for m in ("light", "dark"):
        dispatch(m)
        array(m)
    if CHECK:
        if STALE:
            print("\n".join(f"readme-gifs: {s} is out of date -- run: make readme-art" for s in STALE))
            sys.exit(1)
        print("readme-gifs: previews match the recorded traces")
    else:
        print("gen_readme_gifs: demo_dispatch and demo_array, light and dark")


if __name__ == "__main__":
    main()

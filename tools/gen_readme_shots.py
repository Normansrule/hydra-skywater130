#!/usr/bin/env python3
"""
gen_readme_shots.py -- screenshots of the Silicon Atlas for the READMEs.

Opens docs/site/index.html in a headless Chromium (CHROME_PATH, or the
Playwright build in ~/.cache/ms-playwright) through tools/atlas_shots.mjs, at
1440 by 900, once in light and once in dark, at the views the READMEs show,
and writes web-sized PNGs into docs/img (and the tile's views into
tt/tile/docs/img). The opening story is shot at five scroll positions, one per
step; the deep links (#demos/<trace>/<cycle>) put the player on a recorded
cycle, so a shot shows real data, not an empty player.

A headless browser draws WebGL in software, slowly, so before each story shot
the die view's camera is moved straight to where its spring is heading. That
is the frame a reader sees once the motion settles; nothing else is changed.

These are pictures of the page, not evidence: readme-check does not compare
them, because a browser renders fonts slightly differently from machine to
machine. Re-run after a visible change to the page:

    python3 tools/gen_readme_shots.py
"""
import glob, json, os, pathlib, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SETTLE = ("setTimeout(()=>{const v=document.getElementById('die-hero')._die;if(v){Object.assign(v.cam,v.tgt);"
          "v.v={x:0,y:0,l:0,tilt:0,yaw:0};v.kick()}},1500)")
# name, hash, height, scroll (viewport heights, or a selector), destinations
SHOTS = [
    ("atlas-story", "overview", 900, 0, ["docs/img"]),
    ("atlas-dispatch", "overview", 900, 2.0, ["docs/img", "tt/tile/docs/img"]),
    ("atlas-decision", "overview", 900, 3.0, ["docs/img"]),
    ("atlas-cells", "overview", 900, 4.0, ["docs/img", "tt/tile/docs/img"]),
    ("atlas-exploded", "overview", 900, 5.0, ["docs/img", "tt/tile/docs/img"]),
    ("atlas-switched", "overview", 900, 6.0, ["docs/img", "tt/tile/docs/img"]),
    ("atlas-numbers", "overview", 900, ".bn-red", ["docs/img"]),
    ("atlas-fpga", "overview", 900, "#fpga", ["docs/img"]),
    ("atlas-demo", "demos/crossover/4391", 1180, None, ["docs/img"]),
    ("atlas-array", "demos/tpu/60", 1050, None, ["docs/img"]),
    ("atlas-architecture", "architecture", 820, None, ["docs/img"]),
    ("atlas-layout", "layout", 1000, "#explorer", ["docs/img", "tt/tile/docs/img"]),
    ("atlas-tile", "tile", 1100, None, ["tt/tile/docs/img"]),
    ("atlas-recovery", "demos/recovery/12540", 1180, None, ["tt/tile/docs/img"]),
]


def chrome():
    c = os.environ.get("CHROME_PATH")
    if c:
        return c
    found = sorted(glob.glob(os.path.expanduser("~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome")))
    if not found:
        raise SystemExit("gen_readme_shots: no Chromium; set CHROME_PATH")
    return found[-1]


def main():
    from PIL import Image
    with tempfile.TemporaryDirectory() as tmp:
        jobs = []
        for name, h, height, scroll, dests in SHOTS:
            for dark, suffix in ((False, ""), (True, ".dark")):
                j = {"out": f"{tmp}/{name}{suffix}.png", "hash": h, "width": 1440, "height": height,
                     "dark": dark, "load": 4500, "wait": 2600}
                if scroll is not None:
                    j["scroll"] = scroll
                if h == "overview" and not isinstance(scroll, str):
                    j["eval"] = SETTLE
                jobs.append(j)
        spec = {"chrome": chrome(), "url": (ROOT / "docs/site/index.html").as_uri(), "jobs": jobs}
        jf = pathlib.Path(tmp) / "jobs.json"
        jf.write_text(json.dumps(spec))
        subprocess.run(["node", str(ROOT / "tools/atlas_shots.mjs"), str(jf)], check=True, capture_output=True)
        for name, h, height, scroll, dests in SHOTS:
            for suffix in ("", ".dark"):
                im = Image.open(f"{tmp}/{name}{suffix}.png").convert("RGB")
                im = im.resize((1200, round(im.height * 1200 / 1440)), Image.LANCZOS)
                im = im.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
                for d in dests:
                    out = ROOT / d / f"{name}{suffix}.png"
                    im.save(out, optimize=True)
                    print(f"  {out.relative_to(ROOT)}  {out.stat().st_size // 1024} KiB")


if __name__ == "__main__":
    main()

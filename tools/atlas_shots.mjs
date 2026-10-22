#!/usr/bin/env node
// atlas_shots.mjs -- screenshots of the atlas page in a real headless Chromium,
// driven over the DevTools protocol with no dependencies (Node 22+).
//
//   node tools/atlas_shots.mjs JOBS.json
//
// JOBS.json: {"chrome": path, "url": file URL, "jobs": [{"out": png, "hash": "overview",
//   "width": 1440, "height": 900, "dark": false, "scroll": 0 (viewport heights) or "#selector",
//   "wait": ms, "reduced": false, "eval": "js to run before the shot"}]}
// Each job loads the page fresh, so no state carries from one shot to the next.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const spec = JSON.parse(readFileSync(process.argv[2], "utf8"));
const prof = mkdtempSync(join(tmpdir(), "atlas-shots-"));
const chrome = spawn(spec.chrome, ["--headless=new", "--no-sandbox", "--hide-scrollbars", "--use-angle=swiftshader",
  "--enable-unsafe-swiftshader", "--remote-debugging-port=0", `--user-data-dir=${prof}`, ...(spec.flags || []), "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
const wsUrl = await new Promise((ok, bad) => {
  let buf = ""; chrome.stderr.on("data", d => { buf += d; const m = buf.match(/ws:\/\/[^\s]+/); if (m) ok(m[0]); });
  setTimeout(() => bad(new Error("chrome did not start")), 20000);
});
const ws = new WebSocket(wsUrl);
await new Promise(r => ws.addEventListener("open", r));
let id = 0; const wait = new Map(); const events = [];
ws.addEventListener("message", m => { const d = JSON.parse(m.data); if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } else events.push(d); });
const send = (method, params = {}, sessionId) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params, sessionId })); });
const sleep = ms => new Promise(r => setTimeout(r, ms));

for (const j of spec.jobs) {
  const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
  const { result: { sessionId: s } } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Page.enable", {}, s);
  await send("Emulation.setDeviceMetricsOverride", { width: j.width, height: j.height, deviceScaleFactor: j.scale || 1, mobile: !!j.mobile }, s);
  await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: j.dark ? "dark" : "light" },
    { name: "prefers-reduced-motion", value: j.reduced ? "reduce" : "no-preference" }] }, s);
  await send("Page.navigate", { url: `${spec.url}#${j.hash || "overview"}` }, s);
  await sleep(j.load || 2500);
  if (j.scroll !== undefined) {
    const expr = typeof j.scroll === "string" ? `document.querySelector(${JSON.stringify(j.scroll)}).scrollIntoView({block:"center"})`
      : `window.scrollTo(0, innerHeight * ${j.scroll})`;
    await send("Runtime.evaluate", { expression: expr }, s);
  }
  if (j.eval) await send("Runtime.evaluate", { expression: j.eval, awaitPromise: true }, s);
  await sleep(j.wait || 1800);
  const r = await send("Page.captureScreenshot", { format: "png" }, s);
  if (!r.result) { console.error("atlas_shots: no image for", j.out, JSON.stringify(r.error)); process.exitCode = 1; continue; }
  writeFileSync(j.out, Buffer.from(r.result.data, "base64"));
  const errs = events.filter(e => e.method === "Runtime.exceptionThrown");
  if (errs.length) console.error("atlas_shots: page error:", JSON.stringify(errs[0].params.exceptionDetails).slice(0, 400));
  events.length = 0;
  const st = await send("Runtime.evaluate", { expression: j.probe || "JSON.stringify({y:scrollY})", returnByValue: true }, s);
  console.log("  " + j.out + " " + (st.result && st.result.result ? st.result.result.value : ""));
  await send("Target.closeTarget", { targetId });
}
ws.close(); chrome.kill(); await sleep(300); rmSync(prof, { recursive: true, force: true });

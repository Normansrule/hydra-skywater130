#!/usr/bin/env node
/*
 * cpu_vectors.mjs -- test vectors for hydra_engine_cpu from Sixfold's OWN model
 *
 *   node tools/cpu_vectors.mjs <sixfold checkout> <out dir> [program dir or .s file...]
 *
 * For every program in <sixfold>/programs that halts on its own in the
 * model, writes <out dir>/<program>/:
 *   prog.hex   the assembled image, one byte per line with @address jumps
 *              (Sixfold's assembler, model/asm.js)
 *   regs.txt   x0..x31 after the program, 16 hex digits each, from Sixfold's
 *              cycle-exact model (model/core.js) -- the model Sixfold's own
 *              regression checks its RTL against
 *   console.txt, leds.txt   what it printed through PUTCHAR, its last LED value
 *   info.txt   "<tohost> <cycles> <entry> <cycles with caches> <cycles, compact caches>": the model
 *              without caches (the wrapper's flat memory) and with
 *              Sixfold's caches, miss latency 10 (the CACHED build)
 * and <out dir>/programs.txt. Nothing here is computed by HYDRA code.
 * Programs that wait for buttons, switches or a UART key never halt in the
 * model and are skipped with a note.
 */
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const [root, outDir, ...extra] = process.argv.slice(2);
if (!root || !outDir) { console.error('usage: cpu_vectors.mjs <sixfold checkout> <out dir> [program dir...]'); process.exit(2); }
const asm = await import(url.pathToFileURL(path.resolve(root, 'model/asm.js')));
const core = await import(url.pathToFileURL(path.resolve(root, 'model/core.js')));

fs.mkdirSync(outDir, { recursive: true });
const kept = [];
const dirs = [path.join(root, 'programs'), ...extra];
// an extra argument may also be one .s file (make cpu-fence runs Sixfold's tests/fence_i.s on its own)
const sources = dirs.flatMap((d) => d.endsWith('.s') ? [[path.dirname(d), path.basename(d)]]
  : fs.readdirSync(d).filter((n) => n.endsWith('.s')).sort().map((f) => [d, f]));
for (const [d, f] of sources) {
  const name = f.replace(/\.s$/, '');
  const img = asm.assemble(fs.readFileSync(path.join(d, f), 'utf8'));
  const cfg = { ...core.CONFIGS.performance, caches: false };
  const c = new core.Core(img, cfg);
  while (!c.halted && c.cycle < 2e6) c.step();
  if (!c.halted) { console.log(`skip ${name}: no tohost write within 2,000,000 cycles (waits for input)`); continue; }
  const o = path.join(outDir, name);
  fs.mkdirSync(o, { recursive: true });
  fs.writeFileSync(path.join(o, 'prog.hex'), asm.toHex(img));
  // what it printed through PUTCHAR and its last LED value: the wrapper's UART
  // pin and LED outputs must carry the same (v67)
  fs.writeFileSync(path.join(o, 'console.txt'), c.output);
  fs.writeFileSync(path.join(o, 'leds.txt'), (c.leds >>> 0).toString(16) + '\n');
  fs.writeFileSync(path.join(o, 'regs.txt'), c.regs.map((r) => (BigInt.asUintN(64, BigInt(r))).toString(16).padStart(16, '0')).join('\n') + '\n');
  const tohost = c.csr.tohost;
  // the same program with Sixfold's caches on (the wrapper's CACHED build)
  const cc = new core.Core(img, { ...core.CONFIGS.performance, caches: true, missLatency: 10 });
  while (!cc.halted && cc.cycle < 4e6) cc.step();
  // registers too: a program that reads the cycle counter (23_sha256 does)
  // ends with different values when the caches change its timing
  fs.writeFileSync(path.join(o, 'regs_cached.txt'), cc.regs.map((r) => (BigInt.asUintN(64, BigInt(r))).toString(16).padStart(16, '0')).join('\n') + '\n');
  // and with Sixfold's compact caches (16 sets: 1 KiB each), the chip's build
  const ck = new core.Core(img, { ...core.CONFIGS.compact, missLatency: 10 });
  while (!ck.halted && ck.cycle < 4e6) ck.step();
  fs.writeFileSync(path.join(o, 'regs_compact.txt'), ck.regs.map((r) => (BigInt.asUintN(64, BigInt(r))).toString(16).padStart(16, '0')).join('\n') + '\n');
  fs.writeFileSync(path.join(o, 'info.txt'), `${BigInt(tohost ?? 0).toString(16)} ${c.cycle} ${core.RESET_PC.toString(16)} ${cc.cycle} ${ck.cycle}\n`);
  console.log(`kept ${name}: ${c.cycle} cycles, a0 = 0x${BigInt.asUintN(64, BigInt(c.regs[10])).toString(16)}`);
  kept.push(name);
}
fs.writeFileSync(path.join(outDir, 'programs.txt'), kept.join('\n') + '\n');
console.log(`cpu_vectors: ${kept.length} programs`);

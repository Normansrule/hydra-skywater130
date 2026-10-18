#!/usr/bin/env node
/*
 * cpu_vectors.mjs -- test vectors for hydra_engine_cpu from Sixfold's OWN model
 *
 *   node tools/cpu_vectors.mjs <sixfold checkout> <out dir> [program dir...]
 *
 * For every program in <sixfold>/programs that halts on its own in the
 * model, writes <out dir>/<program>/:
 *   prog.hex   the assembled image, one byte per line with @address jumps
 *              (Sixfold's assembler, model/asm.js)
 *   regs.txt   x0..x31 after the program, 16 hex digits each, from Sixfold's
 *              cycle-exact model (model/core.js) -- the model Sixfold's own
 *              regression checks its RTL against
 *   info.txt   "<tohost> <cycles> <entry>"  (cycles from the model, built
 *              without caches, matching the wrapper's memory)
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
for (const d of dirs) for (const f of fs.readdirSync(d).filter((n) => n.endsWith('.s')).sort()) {
  const name = f.replace(/\.s$/, '');
  const img = asm.assemble(fs.readFileSync(path.join(d, f), 'utf8'));
  const cfg = { ...core.CONFIGS.performance, caches: false };
  const c = new core.Core(img, cfg);
  while (!c.halted && c.cycle < 2e6) c.step();
  if (!c.halted) { console.log(`skip ${name}: no tohost write within 2,000,000 cycles (waits for input)`); continue; }
  const o = path.join(outDir, name);
  fs.mkdirSync(o, { recursive: true });
  fs.writeFileSync(path.join(o, 'prog.hex'), asm.toHex(img));
  fs.writeFileSync(path.join(o, 'regs.txt'), c.regs.map((r) => (BigInt.asUintN(64, BigInt(r))).toString(16).padStart(16, '0')).join('\n') + '\n');
  const tohost = c.csr.tohost;
  fs.writeFileSync(path.join(o, 'info.txt'), `${BigInt(tohost ?? 0).toString(16)} ${c.cycle} ${core.RESET_PC.toString(16)}\n`);
  console.log(`kept ${name}: ${c.cycle} cycles, a0 = 0x${BigInt.asUintN(64, BigInt(c.regs[10])).toString(16)}`);
  kept.push(name);
}
fs.writeFileSync(path.join(outDir, 'programs.txt'), kept.join('\n') + '\n');
console.log(`cpu_vectors: ${kept.length} programs`);

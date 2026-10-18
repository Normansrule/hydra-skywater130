#!/usr/bin/env node
/*
 * gpu_vectors.js -- test vectors for hydra_engine_gpu from Pixelstorm's OWN model
 *
 *   node tools/gpu_vectors.js <pixelstorm checkout> <out dir> <bank words> [kernel dir...]
 *
 * For every kernel in <pixelstorm>/kernels whose memory footprint fits one
 * HYDRA bank, writes into <out dir>/<kernel>/:
 *   imem.hex     the assembled program (Pixelstorm's assembler)
 *   cmem.hex     the kernel parameters c[0..15]
 *   init.hex     the bank before the launch (the kernel's .seq/.data blocks)
 *   expect.hex   the bank after the launch, from Pixelstorm's JavaScript
 *                golden model (web/js/pixelstorm.js, W.Simulator) -- the
 *                same model Pixelstorm's own `make test` checks its RTL
 *                against. Nothing here is computed by HYDRA code.
 *   job.txt      "<grid> <block>"
 * and <out dir>/kernels.txt, one kernel name per line. Extra kernel
 * directories (HYDRA's own test kernels) are assembled and modelled the same
 * way, by Pixelstorm's assembler and model.
 *
 * A kernel is skipped, and the reason printed, when the model touches a word
 * at or beyond the bank size: the HYDRA bank does not wrap the way
 * Pixelstorm's testbench memory does, so such a kernel would be testing the
 * wrapper's range check rather than the GPU.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const [root, outDir, depthArg, ...extra] = process.argv.slice(2);
if (!root || !outDir || !depthArg) {
  console.error('usage: gpu_vectors.js <pixelstorm checkout> <out dir> <bank words>');
  process.exit(2);
}
const DEPTH = parseInt(depthArg, 10);
const W = require(path.resolve(root, 'web/js/pixelstorm.js'));
const hex = (v) => (v >>> 0).toString(16).padStart(8, '0');

fs.mkdirSync(outDir, { recursive: true });
const kept = [];
const files = [];
for (const d of [path.join(root, 'kernels'), ...extra])
  for (const n of fs.readdirSync(d).filter((x) => x.endsWith('.psa')).sort()) files.push(path.join(d, n));
for (const p of files) {
  const f = path.basename(p);
  const src = fs.readFileSync(p, 'utf8');
  const asm = W.assemble(src);
  const cfg = Object.assign({}, W.DEFAULT_CFG, { numSms: 2, cacheLines: 0 });
  const init = new Uint32Array(cfg.gmemWords);
  let fits = true;
  for (const b of asm.config.data) {
    b.values.forEach((v, i) => { init[b.addr + i] = v >>> 0; });
    if (b.addr + b.values.length > DEPTH) fits = false;
  }
  const sim = new W.Simulator(cfg);
  sim.load(asm.words, asm.config.params, asm.config.data);
  const out = sim.run(asm.config.grid, asm.config.block, {});
  for (let a = DEPTH; a < out.gmem.length && fits; a++) if (out.gmem[a] !== init[a]) fits = false;
  const name = f.replace(/\.psa$/, '');
  if (!fits) { console.log(`skip ${name}: touches memory at or beyond word ${DEPTH}`); continue; }
  if (asm.config.block > 32) { console.log(`skip ${name}: block ${asm.config.block} > 32`); continue; }
  const d = path.join(outDir, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'imem.hex'), asm.words.map(hex).join('\n') + '\n');
  const params = Array.from({ length: 16 }, (_, i) => asm.config.params[i] || 0);
  fs.writeFileSync(path.join(d, 'cmem.hex'), params.map(hex).join('\n') + '\n');
  fs.writeFileSync(path.join(d, 'init.hex'), Array.from(init.slice(0, DEPTH)).map(hex).join('\n') + '\n');
  fs.writeFileSync(path.join(d, 'expect.hex'), Array.from(out.gmem.slice(0, DEPTH)).map(hex).join('\n') + '\n');
  fs.writeFileSync(path.join(d, 'job.txt'), `${asm.config.grid} ${asm.config.block} ${asm.words.length}\n`);
  let changed = 0;
  for (let a = 0; a < DEPTH; a++) if (out.gmem[a] !== init[a]) changed++;
  console.log(`kept ${name}: grid ${asm.config.grid} block ${asm.config.block}, ${asm.words.length} instructions, ${changed} words written by the model`);
  kept.push(name);
}
fs.writeFileSync(path.join(outDir, 'kernels.txt'), kept.join('\n') + '\n');
console.log(`gpu_vectors: ${kept.length} kernels`);

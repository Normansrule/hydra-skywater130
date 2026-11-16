#!/usr/bin/env node
/*
 * baremetal_vectors.mjs -- test vectors for a bare-metal C program, from
 * Sixfold's OWN model, in the layout tools/cpu_vectors.mjs writes
 *
 *   node tools/baremetal_vectors.mjs <sixfold checkout> <image.bin> <base hex> <out dir> [expected console text file]
 *
 * <image.bin> is `objcopy -O binary` of the linked ELF, whose lowest address
 * is <base>. Writes <out dir>/prog.hex, regs.txt, regs_cached.txt,
 * regs_compact.txt, info.txt and console.txt (what the program printed
 * through the putchar register, in the model). With a fifth argument, the
 * console must equal that file exactly or this exits 1. Nothing here is
 * computed by HYDRA code.
 */
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const [root, bin, baseHex, outDir, expectFile] = process.argv.slice(2);
if (!root || !bin || !baseHex || !outDir) {
  console.error('usage: baremetal_vectors.mjs <sixfold> <image.bin> <base hex> <out dir> [expected console]'); process.exit(2);
}
const core = await import(url.pathToFileURL(path.resolve(root, 'model/core.js')));
const base = parseInt(baseHex, 16);
const code = fs.readFileSync(bin);
if (base + code.length > 65536) { console.error(`baremetal_vectors: image ends at 0x${(base + code.length).toString(16)}, past 64 KiB`); process.exit(1); }
if (base !== core.RESET_PC) console.log(`note: image base 0x${base.toString(16)} is not the reset PC 0x${core.RESET_PC.toString(16)}`);
const mem = new Uint8Array(65536); mem.set(code, base);

const hex = (r) => BigInt.asUintN(64, BigInt(r)).toString(16).padStart(16, '0');
function run(cfg, limit) {
  const c = new core.Core(mem, cfg);
  while (!c.halted && c.cycle < limit) c.step();
  if (!c.halted) { console.error(`baremetal_vectors: no TOHOST write within ${limit} cycles`); process.exit(1); }
  return c;
}
const flat = run({ ...core.CONFIGS.performance, caches: false }, 4e6);
const cached = run({ ...core.CONFIGS.performance, caches: true, missLatency: 10 }, 8e6);
const compact = run({ ...core.CONFIGS.compact, missLatency: 10 }, 8e6);
for (const [n, c] of [['cached', cached], ['compact', compact]])
  if (c.output !== flat.output || c.csr.tohost !== flat.csr.tohost) {
    console.error(`baremetal_vectors: the ${n} model printed or returned something else than the flat model`); process.exit(1);
  }

fs.mkdirSync(outDir, { recursive: true });
const lines = [`@${base.toString(16).padStart(8, '0')}`, ...Array.from(code, (b) => b.toString(16).padStart(2, '0'))];
fs.writeFileSync(path.join(outDir, 'prog.hex'), lines.join('\n') + '\n');
fs.writeFileSync(path.join(outDir, 'regs.txt'), flat.regs.map(hex).join('\n') + '\n');
fs.writeFileSync(path.join(outDir, 'regs_cached.txt'), cached.regs.map(hex).join('\n') + '\n');
fs.writeFileSync(path.join(outDir, 'regs_compact.txt'), compact.regs.map(hex).join('\n') + '\n');
fs.writeFileSync(path.join(outDir, 'info.txt'),
  `${BigInt(flat.csr.tohost).toString(16)} ${flat.cycle} ${core.RESET_PC.toString(16)} ${cached.cycle} ${compact.cycle}\n`);
fs.writeFileSync(path.join(outDir, 'console.txt'), flat.output);
fs.writeFileSync(path.join(outDir, 'leds.txt'), (flat.leds >>> 0).toString(16) + '\n');
const tohost = BigInt(flat.csr.tohost);
console.log(`model: TOHOST 0x${tohost.toString(16)} (main returned 0x${(tohost >> 1n).toString(16)}), `
  + `${flat.cycle} cycles flat, ${cached.cycle} with 4 KiB caches, ${compact.cycle} with the chip's 1 KiB caches`);
process.stdout.write(flat.output.split('\n').map((l) => l && `  | ${l}`).join('\n'));
if ((tohost & 0xFFn) === 0xFFn) { console.error('baremetal_vectors: the program ended in a trap'); process.exit(1); }
if (expectFile) {
  const want = fs.readFileSync(expectFile, 'utf8');
  if (want !== flat.output) { console.error(`baremetal_vectors: console differs from ${expectFile}`); process.exit(1); }
  console.log(`console matches ${expectFile}`);
}

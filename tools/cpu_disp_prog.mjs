#!/usr/bin/env node
/*
 * cpu_disp_prog.mjs -- a Sixfold program that uses the CPU's dispatch port
 *
 *   node tools/cpu_disp_prog.mjs <sixfold checkout> <out dir>
 *
 * Writes <out>/prog.hex (assembled by Sixfold's own assembler, model/asm.js)
 * and <out>/expect.txt: "<descriptor hex> <entry hex>". The descriptor and
 * headers are packed here from the documented field layout (mom_pkg
 * work_desc_t, docs/architecture/heterogeneous-system.md), not taken from RTL.
 *
 * The program, running on the CPU as a scheduled job:
 *   1. hands a 4x4x4 INT8 matrix multiply, forced to the TPU, to the scheduler
 *   2. waits until the dispatch port counts it completed
 *   3. hands over a job forced to the CPU itself, which must be refused
 *      ("no eligible engine", code 7) and never queued behind the program
 *   4. a0 = the final STATUS word; halt (TOHOST 1). Any other ending writes a
 *      TOHOST of 2 or more.
 * Sixfold's model cannot run it (it has no dispatch port), so tb_sys_tile_disp
 * checks it against these expectations instead.
 */
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const [root, out] = process.argv.slice(2);
if (!root || !out) { console.error('usage: cpu_disp_prog.mjs <sixfold checkout> <out dir>'); process.exit(2); }
const asm = await import(url.pathToFileURL(path.resolve(root, 'model/asm.js')));

const field = (v, hi, lo) => (BigInt(v) & ((1n << BigInt(hi - lo + 1)) - 1n)) << BigInt(lo);
// work_desc_t: op_class[127:124] dtype[123:121] lat[120:119] pwr[118:117]
//              m[116:101] n[100:85] k[84:69] bytes[68:45] src[44:43] tag[42:35]
const desc = field(3, 127, 124) | field(0, 123, 121) | field(1, 120, 119) | field(1, 118, 117)
           | field(4, 116, 101) | field(4, 100, 85) | field(4, 84, 69) | field(48, 68, 45) | field(0x5A, 42, 35);
// ABI version 2 header: ver[63:60] mode[59:58] policy[57:55] ctx[54:47] epoch[46:31]
const hdr = (pol) => field(2, 63, 60) | field(0, 59, 58) | field(pol, 57, 55) | field(1, 54, 47) | field(7, 46, 31);
const hex = (v) => '0x' + v.toString(16);
const lo = desc & ((1n << 64n) - 1n), hi = desc >> 64n;

const src = `
    .equ DEV, 0x10000000
    li   s0, DEV
    li   t0, ${hex(lo)}
    sd   t0, 0x100(s0)          # DESC_LO
    li   t0, ${hex(hi)}
    sd   t0, 0x108(s0)          # DESC_HI
    li   t0, ${hex(hdr(3))}
    sd   t0, 0x110(s0)          # HDR: policy TPU
    sd   zero, 0x118(s0)        # SUBMIT
    li   t5, 200000
wait_done:
    addi t5, t5, -1
    beqz t5, timeout
    ld   t1, 0x120(s0)          # STATUS
    srli t2, t1, 32
    andi t2, t2, 0xff           # completed
    beqz t2, wait_done
    li   t0, ${hex(hdr(1))}
    sd   t0, 0x110(s0)          # HDR: policy CPU -- the CPU itself
    sd   zero, 0x118(s0)        # SUBMIT
    li   t5, 200000
wait_ref:
    addi t5, t5, -1
    beqz t5, timeout
    ld   t1, 0x120(s0)
    srli t2, t1, 8
    andi t2, t2, 0xff           # refused
    beqz t2, wait_ref
    srli t3, t1, 16
    andi t3, t3, 0xf            # last refusal code
    li   t4, 7
    bne  t3, t4, bad_code
    mv   a0, t1
    halt
timeout:
    csrwi tohost, 2
    j    timeout
bad_code:
    csrwi tohost, 3
    j    bad_code
`;
const img = asm.assemble(src);
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'prog.hex'), asm.toHex(img));
fs.writeFileSync(path.join(out, 'expect.txt'), `${desc.toString(16).padStart(32, '0')} ${asm.RESET_PC.toString(16)}\n`);
console.log(`cpu_disp_prog: descriptor ${desc.toString(16).padStart(32, '0')}`);

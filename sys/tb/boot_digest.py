#!/usr/bin/env python3
"""boot_digest.py -- SHA-256 of a CPU program image as the chip's memory holds it.

Reads a $readmemh byte file (prog.hex from tools/cpu_vectors.mjs, with @address
lines) into the CPU's 64 KiB memory, zero elsewhere, exactly as
tb_sys_tile_boot loads it, and prints hashlib's digest of all 65,536 bytes.
That digest is the BOOT_GOLDEN the bench builds the chip with.

    python3 sys/tb/boot_digest.py <prog.hex> [words]

With [words], only the first words * 4 bytes are hashed: what a boot of that
length reads.
"""
import hashlib
import sys

mem = bytearray(65536)
addr = 0
for tok in open(sys.argv[1]).read().split():
    if tok.startswith("@"):
        addr = int(tok[1:], 16)
    else:
        mem[addr] = int(tok, 16)
        addr += 1
n = 4 * int(sys.argv[2]) if len(sys.argv) > 2 else len(mem)
print(hashlib.sha256(bytes(mem[:n])).hexdigest())

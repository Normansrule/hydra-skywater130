#!/usr/bin/env python3
"""secure_boot_model.py -- the outside reference for hydra_secure_boot.

hashlib computes every digest and the measured-boot chain; nothing here is
taken from the RTL. It writes a random image as CPU memory words, the digest
the mask must hold for it (GOLDEN), the digest of a copy with one byte
changed, and the PCR after each boot the bench performs:

    boot 1  the tampered image          -> FAILED, PCR = H(0 || d_tampered)
    boot 2  length 0                    -> FAILED at once, nothing hashed
    boot 3  length past the memory      -> FAILED at once, nothing hashed
    boot 4  the real image              -> VERIFIED, PCR = H(PCR || d_golden)
    boot 5  after VERIFIED              -> ignored

    python3 sec/tb/secure_boot_model.py <outdir> [words] [seed]
writes <outdir>/sb_image.hex (one little-endian memory word per line) and
<outdir>/sb_meta.txt: words, tamper word, tamper byte, golden, d_tampered,
pcr1, pcr4 (all hex but the first three).
"""
import hashlib
import random
import sys


def main():
    out = sys.argv[1]
    nwords = int(sys.argv[2]) if len(sys.argv) > 2 else 777
    rnd = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 0x5B007)
    img = bytes(rnd.getrandbits(8) for _ in range(4 * nwords))
    tw = rnd.randrange(nwords)
    tb = rnd.randrange(4)
    bad = bytearray(img)
    bad[4 * tw + tb] ^= 0x01                      # one bit, anywhere in the image
    golden = hashlib.sha256(img).digest()
    d_bad = hashlib.sha256(bytes(bad)).digest()
    pcr1 = hashlib.sha256(bytes(32) + d_bad).digest()
    pcr4 = hashlib.sha256(pcr1 + golden).digest()
    with open(f"{out}/sb_image.hex", "w") as f:
        for w in range(nwords):
            word = int.from_bytes(img[4 * w:4 * w + 4], "little")   # byte 0 in bits 7:0
            f.write(f"{word:08x}\n")
    with open(f"{out}/sb_meta.txt", "w") as f:
        f.write(f"{nwords} {tw} {tb} {golden.hex()} {d_bad.hex()} {pcr1.hex()} {pcr4.hex()}\n")
    print(golden.hex())


if __name__ == "__main__":
    main()

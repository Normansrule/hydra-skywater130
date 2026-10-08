#!/usr/bin/env python3
"""
measure_model.py -- expected PCR after measuring a sequence of images.

    PCR <- SHA-256( PCR || SHA-256(image) ),  PCR starts at 32 zero bytes

Both hashes come from hashlib. The images straddle the padding boundaries
(empty, 55 and 56 bytes, a whole block) and include one long image, so the
check covers the stream's padding as well as the chaining.
"""
import hashlib, pathlib, random

HERE = pathlib.Path(__file__).resolve().parent
LENGTHS = [0, 3, 55, 56, 64, 300, 1000]


def main():
    rng = random.Random(1007)
    words, meta = [], []
    pcr = bytes(32)
    for n in LENGTHS:
        img = bytes(rng.randrange(256) for _ in range(n))
        nw = max(1, (n + 3) // 4)
        for i in range(nw):
            words.append(int.from_bytes(img[4 * i: 4 * i + 4].ljust(4, b"\0"), "big"))
        d = hashlib.sha256(img).digest()
        pcr = hashlib.sha256(pcr + d).digest()
        meta.append(f"{n} {nw} {n - 4 * (nw - 1)} {d.hex()} {pcr.hex()}")
    (HERE / "measure_words.hex").write_text("\n".join(f"{w:08x}" for w in words) + "\n")
    (HERE / "measure_meta.txt").write_text("\n".join(meta) + "\n")
    print(f"measure_model: {len(LENGTHS)} images, final PCR {pcr.hex()}")


if __name__ == "__main__":
    main()

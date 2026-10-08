#!/usr/bin/env python3
"""
sha256_stream_model.py -- messages and their digests, from hashlib.

The hardware is given MESSAGE BYTES ONLY, packed big-endian into 32-bit
words (first byte in bits 31:24), with a byte count on the last word. It
must do its own padding. So unlike sha256_model.py, nothing here pads:
the expected digest is hashlib's, of the raw bytes.

Lengths cover every value from 0 to 130 bytes -- every position the 0x80
marker can land in a word and in a block, across the 55/56-byte boundary
where the length no longer fits and a second padding block is needed, and
the 63/64 boundary where the message itself fills a block -- then the same
boundaries two and three blocks in, and one long message.
"""
import hashlib, pathlib, random

HERE = pathlib.Path(__file__).resolve().parent
LENGTHS = list(range(0, 131)) + [183, 184, 191, 192, 247, 248, 255, 256, 1000]


def main():
    rng = random.Random(20261007)
    words, meta = [], []
    for n in LENGTHS:
        msg = bytes(rng.randrange(256) for _ in range(n))
        nw = max(1, (n + 3) // 4)                 # empty message: one word, 0 bytes
        for i in range(nw):
            chunk = msg[4 * i: 4 * i + 4]
            words.append(int.from_bytes(chunk.ljust(4, b"\0"), "big"))
        last_bytes = n - 4 * (nw - 1)
        meta.append(f"{n} {nw} {last_bytes} {hashlib.sha256(msg).hexdigest()}")
    (HERE / "sha256_stream_words.hex").write_text("\n".join(f"{w:08x}" for w in words) + "\n")
    (HERE / "sha256_stream_meta.txt").write_text("\n".join(meta) + "\n")
    print(f"sha256_stream_model: {len(LENGTHS)} messages, {len(words)} words, digests from hashlib")


if __name__ == "__main__":
    main()

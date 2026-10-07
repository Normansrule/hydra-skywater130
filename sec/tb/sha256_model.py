#!/usr/bin/env python3
"""
sha256_model.py -- padded blocks and expected digests, from hashlib.

The reference here is Python's hashlib, which was written by people with no
connection to this project and is checked against the published vectors by
everyone who uses it. That makes this the strongest model in the repository:
for the other engines a disagreement could mean either side misread the
contract; here a disagreement means the hardware is wrong.

The padding is done HERE, in software, because the hardware compresses
blocks and does not frame messages. The rule is the standard's: append a 1
bit, then zeros, then the 64-bit length in bits, so the total is a multiple
of 512. Getting this wrong is the classic way to produce a hash engine that
passes on "abc" and fails on anything 56 bytes or longer, so the cases below
deliberately straddle that boundary.
"""
import hashlib, pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent


def pad(msg: bytes) -> bytes:
    ml = len(msg) * 8
    out = msg + b"\x80"
    while len(out) % 64 != 56:
        out += b"\x00"
    return out + ml.to_bytes(8, "big")


CASES = [
    b"",                                  # empty: one block of pure padding
    b"abc",                               # the published short vector
    b"a" * 55,                            # longest that still fits one block
    b"a" * 56,                            # first that needs two: the classic bug
    b"a" * 64,                            # exactly one block of message
    b"The quick brown fox jumps over the lazy dog",
    bytes(range(256)),                    # every byte value, five blocks
]


def main():
    blocks, meta = [], []
    for msg in CASES:
        p = pad(msg)
        nb = len(p) // 64
        for i in range(0, len(p), 4):
            blocks.append(int.from_bytes(p[i:i+4], "big"))
        meta.append(f"{nb} {hashlib.sha256(msg).hexdigest()}")

    (HERE / "sha256_blocks.hex").write_text(
        "\n".join(f"{w:08x}" for w in blocks) + "\n")
    (HERE / "sha256_meta.txt").write_text("\n".join(meta) + "\n")
    print(f"sha256_model: {len(CASES)} messages, "
          f"{sum(int(m.split()[0]) for m in meta)} blocks, digests from hashlib")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
pcr_model.py -- what the measurement register should hold after a sequence
of extends, computed with hashlib.

    PCR <- SHA-256( PCR || measurement )

starting from all zeros. Same reasoning as the hash bench: the reference is
a library nobody here wrote, so a disagreement means the hardware is wrong.

The file also records the digest after EVERY step, not just the last, so a
failure says which extend went wrong instead of only that the final value
differs.
"""
import hashlib, pathlib

HERE = pathlib.Path(__file__).resolve().parent

MEAS = [
    bytes(32),                                  # all zeros
    bytes([0xFF] * 32),                         # all ones
    bytes(range(32)),                           # counting
    hashlib.sha256(b"bootloader stage 1").digest(),
    hashlib.sha256(b"kernel").digest(),
    bytes([0xA5] * 32),
]


def main():
    pcr = bytes(32)
    lines, steps = [], []
    for m in MEAS:
        pcr = hashlib.sha256(pcr + m).digest()
        lines.append(m.hex())
        steps.append(pcr.hex())
    (HERE / "pcr_meas.txt").write_text("\n".join(lines) + "\n")
    (HERE / "pcr_exp.txt").write_text("\n".join(steps) + "\n")
    print(f"pcr_model: {len(MEAS)} extends, final {pcr.hex()}")

    # Extending is order-dependent: the same measurements in a different
    # order must give a different register. If this ever fails the operation
    # is not a chain and the record proves nothing about sequence.
    a = bytes(32)
    for m in MEAS[:2]:
        a = hashlib.sha256(a + m).digest()
    b = bytes(32)
    for m in reversed(MEAS[:2]):
        b = hashlib.sha256(b + m).digest()
    assert a != b, "extend is order-independent -- that would not be a chain"
    print("pcr_model: order dependence holds")


if __name__ == "__main__":
    main()

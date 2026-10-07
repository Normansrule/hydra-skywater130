#!/usr/bin/env python3
"""
cdc_check.py -- structural check on the clock crossing.

WHY THIS EXISTS RATHER THAN A TEST

Mutation testing the bridge killed a broken handshake and a missing busy
guard, and did NOT kill this:

    req_sync <= {req_sync[0], req_tog};     ->     req_sync <= {req_tog, req_tog};

That mutation removes a synchroniser stage. In an event simulator the two
are indistinguishable -- signals change instantaneously and metastability
does not exist -- so no amount of simulation catches it, and reporting it as
a "surviving mutant" without explanation would invite someone to conclude
the stage is unnecessary. It is not: with one stage, a signal captured while
changing can propagate a half-resolved value into logic that then disagrees
with itself.

Being un-simulatable does not make it uncheckable. The property is
structural: each signal crossing a clock boundary must pass through a
two-flop chain whose first stage takes the foreign signal and whose second
takes the first. That is what this reads out of the source.

It is a text check, and its limits should be stated: it verifies the
synchronisers that are DECLARED here have the right shape. It cannot find a
crossing nobody wrote a synchroniser for. A real clock-domain-crossing tool
derives the clock domains and finds those; this is a guard against the
specific regression mutation testing exposed.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "rtl/hydra_jtag_bridge.sv"

# name of the 2-bit synchroniser, and the foreign signal it samples
EXPECTED = [("ack_sync", "ack_tog_sys"), ("req_sync", "req_tog")]


def main():
    text = SRC.read_text()
    problems = []

    for sync, foreign in EXPECTED:
        m = re.search(rf"{sync}\s*<=\s*\{{([^}}]*)\}}\s*;", text)
        if not m:
            problems.append(f"{sync}: no shift assignment found at all")
            continue
        parts = [p.strip() for p in m.group(1).split(",")]
        if len(parts) != 2:
            problems.append(f"{sync}: {len(parts)} stages, expected 2 -- {m.group(1)}")
            continue
        first, second = parts
        if first != f"{sync}[0]":
            problems.append(
                f"{sync}: second stage samples '{first}', expected '{sync}[0]'. "
                f"Both stages taking the foreign signal is a ONE-flop "
                f"synchroniser wearing two flops.")
        if second != foreign:
            problems.append(
                f"{sync}: first stage samples '{second}', expected '{foreign}'")

        decl = re.search(rf"logic\s*\[1:0\]\s*{sync}\s*;", text)
        if not decl:
            problems.append(f"{sync}: not declared as a 2-bit register")

    # The payload must NOT be synchronised -- it is held still by the
    # handshake, and per-bit synchronisers would let a word cross half-old
    # and half-new. Catch anyone "fixing" that.
    for payload in ("addr_q", "wdata_q"):
        if re.search(rf"{payload}_sync|sync_{payload}", text):
            problems.append(
                f"{payload} appears to be synchronised bit by bit. It must "
                f"not be: it is held stable across the handshake, and "
                f"per-bit synchronisers would let it cross half-old.")

    if problems:
        print("cdc_check: FAIL")
        for p in problems:
            print(f"  {p}")
        sys.exit(1)
    print(f"cdc_check: PASS -- {len(EXPECTED)} two-flop synchronisers correct, "
          f"payload crosses unsynchronised as designed")


if __name__ == "__main__":
    main()

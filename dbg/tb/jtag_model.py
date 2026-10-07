#!/usr/bin/env python3
"""
jtag_model.py -- the test access port, written from IEEE 1149.1's state
diagram rather than from the RTL.

The point of a separate model is that a misreading of the standard shows up
as a disagreement instead of being copied into both. So this is written from
the transition table as published: sixteen states, next state chosen by TMS,
and nothing borrowed from hydra_jtag_tap.sv.

It emits a stimulus file of TMS/TDI bits and the TDO the standard says must
come back, which tb_jtag_tap.sv replays bit for bit.
"""
import pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent

TLR, RTI, SDRS, CDR, SDR, E1DR, PDR, E2DR, UDR, SIRS, CIR, SIR, E1IR, PIR, E2IR, UIR = range(16)
NAMES = "TLR RTI SEL-DR CAP-DR SHF-DR EX1-DR PSE-DR EX2-DR UPD-DR SEL-IR CAP-IR SHF-IR EX1-IR PSE-IR EX2-IR UPD-IR".split()

# next[state][tms]
NEXT = {
    TLR: (RTI, TLR),   RTI: (RTI, SDRS),  SDRS: (CDR, SIRS), CDR: (SDR, E1DR),
    SDR: (SDR, E1DR),  E1DR: (PDR, UDR),  PDR: (PDR, E2DR),  E2DR: (SDR, UDR),
    UDR: (RTI, SDRS),  SIRS: (CIR, TLR),  CIR: (SIR, E1IR),  SIR: (SIR, E1IR),
    E1IR: (PIR, UIR),  PIR: (PIR, E2IR),  E2IR: (SIR, UIR),  UIR: (RTI, SDRS),
}

IRW = 4
DRW = 40
IDCODE = 0x1130001D
INST_IDCODE, INST_USER, INST_BYPASS = 0x1, 0x8, 0xF


class Tap:
    """Bit-accurate model. TDO is presented on the falling edge, so the bit
    observed alongside a rising edge is the one selected BEFORE that edge."""

    def __init__(self, capture_value=0):
        self.st = TLR
        self.ir = INST_IDCODE
        self.ir_shift = 0
        self.id_shift = 0
        self.user_shift = 0
        self.bypass = 0
        self.user_dr = 0
        self.updates = []
        self.capture_value = capture_value

    def driving(self):
        """The output is only driven while shifting; at any other time the
        pin is released and its value means nothing."""
        return self.st in (SDR, SIR)

    def tdo(self):
        if self.st == SIR:
            return self.ir_shift & 1
        if self.st == SDR:
            if self.ir == INST_IDCODE:
                return self.id_shift & 1
            if self.ir == INST_USER:
                return self.user_shift & 1
            return self.bypass & 1
        return 0

    def edge(self, tms, tdi):
        """One rising TCK. Returns the TDO bit valid during this edge."""
        out = self.tdo()
        st = self.st

        if st == TLR:
            self.ir = INST_IDCODE
        elif st == CIR:
            self.ir_shift = 0b01
        elif st == SIR:
            self.ir_shift = (self.ir_shift >> 1) | (tdi << (IRW - 1))
        elif st == UIR:
            self.ir = self.ir_shift

        if st == CDR:
            self.id_shift = IDCODE
            self.user_shift = self.capture_value
            self.bypass = 0
        elif st == SDR:
            self.id_shift = (self.id_shift >> 1) | (tdi << 31)
            self.user_shift = (self.user_shift >> 1) | (tdi << (DRW - 1))
            self.bypass = tdi
        elif st == UDR and self.ir == INST_USER:
            self.user_dr = self.user_shift
            self.updates.append(self.user_shift)

        self.st = NEXT[st][tms]
        return out


def seq(bits):
    return [(int(t), int(d)) for t, d in bits]


def goto_shift_ir():
    #  TLR -> RTI -> SEL-DR -> SEL-IR -> CAP-IR -> SHF-IR
    return [(0, 0), (1, 0), (1, 0), (0, 0), (0, 0)]


def goto_shift_dr():
    #  RTI -> SEL-DR -> CAP-DR -> SHF-DR
    return [(1, 0), (0, 0), (0, 0)]


def load_ir(value):
    out = goto_shift_ir()
    for i in range(IRW):
        last = (i == IRW - 1)
        out.append((1 if last else 0, (value >> i) & 1))   # exit on last bit
    out += [(1, 0), (0, 0)]                                 # UPD-IR -> RTI
    return out


def shift_dr(nbits, value=0):
    out = goto_shift_dr()
    for i in range(nbits):
        last = (i == nbits - 1)
        out.append((1 if last else 0, (value >> i) & 1))
    out += [(1, 0), (0, 0)]                                 # UPD-DR -> RTI
    return out


def main():
    cap = 0x5A_A5_3C_C3_96
    tap = Tap(capture_value=cap)

    stim = []
    stim += [(1, 0)] * 6                       # any state -> TLR, the standard's escape
    stim += load_ir(INST_IDCODE)
    stim += shift_dr(32)                       # read the identification code
    stim += load_ir(INST_USER)
    stim += shift_dr(DRW, 0x01_2345_6789)      # write the user register, read the capture
    stim += load_ir(INST_BYPASS)
    stim += shift_dr(4, 0b1011)                # bypass: one flop of delay
    stim += load_ir(INST_USER)
    stim += shift_dr(DRW, 0xAA_5555_AAAA)
    # Idle in Run-Test/Idle afterwards. The update pulse is registered, so it
    # appears one clock AFTER the Update-DR edge; ending the stimulus there
    # would leave the last update unobservable -- by the bench and by a real
    # probe alike.
    stim += [(0, 0)] * 4

    lines, states = [], []
    for tms, tdi in stim:
        states.append(NAMES[tap.st])
        drv = tap.driving()
        out = tap.edge(tms, tdi)
        lines.append(f"{tms} {tdi} {out} {1 if drv else 0}")

    (HERE / "jtag_stim.txt").write_text("\n".join(lines) + "\n")
    (HERE / "jtag_meta.txt").write_text(
        f"{len(lines)}\n{IDCODE:08x}\n{cap:010x}\n"
        + "\n".join(f"{u:010x}" for u in tap.updates) + "\n")
    print(f"jtag_model: {len(lines)} TCK edges, identification code {IDCODE:08x}, "
          f"{len(tap.updates)} user updates {[f'{u:010x}' for u in tap.updates]}")


if __name__ == "__main__":
    main()

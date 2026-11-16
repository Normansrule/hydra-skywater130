#!/usr/bin/env python3
"""i2c_gpio_model.py -- the independent model for hydra_i2c_gpio.

Written from the register map in the RTL header, not from the RTL: an I2C
target at one 7-bit address, eight 8-bit registers, a pointer that
auto-increments after every data byte. It generates a random sequence of bus
transactions and writes, for each one, what a correct target must answer.
tb_i2c_gpio.sv replays the file against the RTL and compares.

    python3 common/tb/i2c_gpio_model.py <out.txt> [count] [seed]

Lines (all numbers hex):
    PADS  <value>                       drive gpio_in
    WR    <addr7> <ack> <n> <b0> ...    S addr+W (ptr and data bytes) P;
                                        ack = 1 if the target must ACK all
    RD    <addr7> <ack> <ptr> <n> <e0> ...
                                        S addr+W ptr Sr addr+R, read n bytes,
                                        ACK all but the last; e* expected
    PINS  <out> <oe>                    expected gpio_out, gpio_oe

The host bus (registers 0x10-0x16) is modelled on a memory of four banks;
the bench gives the target the same memory with a two-cycle read.
"""
import random
import sys

ADDR = 0x2A
NGPIO = 15
MASK = (1 << NGPIO) - 1
MASK_REV = 0xC0DE1301          # what tb_i2c_gpio ties to mask_rev


class Target:
    def __init__(self):
        self.out = 0
        self.oe = 0
        self.owner = 0             # 0x0D: which GPIO the CPU drives (v67)
        self.pads = 0
        self.ptr = 0
        self.bank = 0
        self.hold = 0
        self.addr = 0
        self.wbuf = 0
        self.snap = 0
        self.mem = {}                # (bank, addr) -> word; unwritten words read 0

    @staticmethod
    def next_ptr(a):
        return 0x13 if a == 0x16 else (a + 1) & 0xFF

    def read(self, a):
        # side effects of sending a byte: 0x13 snapshots the word, 0x16 steps the address
        if a == 0x13:
            self.snap = self.mem.get((self.bank, self.addr), 0)
        v = self.peek(a)
        if a == 0x16 and not self.hold:
            self.addr = (self.addr + 1) & 0xFFFF
        return v

    def peek(self, a):
        return {
            0x0C: 1, 0x0D: self.owner,
            0x10: self.bank | (self.hold << 7), 0x11: self.addr >> 8, 0x12: self.addr & 0xFF,
            0x13: self.snap >> 24, 0x14: (self.snap >> 16) & 0xFF,
            0x15: (self.snap >> 8) & 0xFF, 0x16: self.snap & 0xFF,
            0x00: 0x48,
            0x01: self.out & 0xFF, 0x02: self.out >> 8,
            0x03: self.oe & 0xFF, 0x04: self.oe >> 8,
            0x05: self.pads & 0xFF, 0x06: self.pads >> 8,
            0x07: NGPIO,
            0x08: MASK_REV >> 24, 0x09: (MASK_REV >> 16) & 0xFF,
            0x0A: (MASK_REV >> 8) & 0xFF, 0x0B: MASK_REV & 0xFF,
        }.get(a, 0)

    def write(self, a, v):
        hi = (1 << (NGPIO - 8)) - 1
        if a == 0x01:
            self.out = (self.out & 0xFF00) | v
        elif a == 0x02:
            self.out = (self.out & 0x00FF) | ((v & hi) << 8)
        elif a == 0x03:
            self.oe = (self.oe & 0xFF00) | v
        elif a == 0x04:
            self.oe = (self.oe & 0x00FF) | ((v & hi) << 8)
        elif a == 0x0D:
            self.owner = v & 3
        elif a == 0x10:
            self.bank = v & 3
            self.hold = v >> 7
        elif a == 0x11:
            self.addr = (self.addr & 0x00FF) | (v << 8)
        elif a == 0x12:
            self.addr = (self.addr & 0xFF00) | v
        elif a in (0x13, 0x14, 0x15):
            sh = 8 * (0x16 - a) - 8
            self.wbuf = (self.wbuf & ~(0xFF << sh) & 0xFFFFFF) | (v << sh)
        elif a == 0x16:
            self.mem[(self.bank, self.addr)] = (self.wbuf << 8) | v
            if not self.hold:
                self.addr = (self.addr + 1) & 0xFFFF


def main():
    out = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    rnd = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 0x12C)
    t = Target()
    lines = []
    stats = {"wr": 0, "rd": 0, "nack": 0, "pads": 0}

    def ptr_choice():
        return rnd.choice([rnd.randrange(12), rnd.randrange(12), rnd.randrange(0x0C, 0x17), rnd.randrange(256)])

    # Fixed opening: identity, then every register written and read back.
    lines.append(f"RD {ADDR:x} 1 0 c " + " ".join(f"{t.peek(a):x}" for a in range(12)))
    for _ in range(count):
        r = rnd.random()
        if r < 0.15:
            t.pads = rnd.getrandbits(NGPIO)
            lines.append(f"PADS {t.pads:x}")
            stats["pads"] += 1
        elif r < 0.55:
            if rnd.random() < 0.3:              # a host-bus burst: bank, address, words
                p = 0x10
                words = rnd.randrange(1, 5)
                data = [rnd.randrange(4) | (0x80 if rnd.random() < 0.25 else 0), rnd.choice([0, 1, rnd.getrandbits(8)]), rnd.getrandbits(8)]
                data += [rnd.getrandbits(8) for _ in range(4 * words)]
            else:
                p = ptr_choice()
                data = [rnd.getrandbits(8) for _ in range(rnd.randrange(0, 5))]
            n = len(data)
            lines.append(f"WR {ADDR:x} 1 {n + 1:x} {p:x} " + " ".join(f"{d:x}" for d in data))
            a = p
            for d in data:
                t.write(a, d)
                a = t.next_ptr(a)
            lines.append(f"PINS {t.out:x} {t.oe:x}")
            stats["wr"] += 1
        elif r < 0.9:
            if rnd.random() < 0.3:              # read words back over the host bus
                p, n = 0x13, 4 * rnd.randrange(1, 4)
            else:
                p, n = ptr_choice(), rnd.randrange(1, 6)
            exp, a = [], p
            for _ in range(n):
                exp.append(t.read(a))
                a = t.next_ptr(a)
            lines.append(f"RD {ADDR:x} 1 {p:x} {n:x} " + " ".join(f"{e:x}" for e in exp))
            stats["rd"] += 1
        else:
            other = rnd.choice([a for a in range(1, 0x78) if a != ADDR])
            if rnd.random() < 0.5:
                lines.append(f"WR {other:x} 0 2 1 ff")
            else:
                lines.append(f"RD {other:x} 0 0 1 0")
            lines.append(f"PINS {t.out:x} {t.oe:x}")
            stats["nack"] += 1
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"i2c_gpio_model: {len(lines)} lines, {stats['wr']} writes, {stats['rd']} reads, "
          f"{stats['nack']} to other addresses, {stats['pads']} pad changes")


if __name__ == "__main__":
    main()

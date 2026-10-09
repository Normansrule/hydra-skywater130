#!/usr/bin/env python3
"""
hydra_host.py -- drive the TT-A tile from a PC, over an FPGA board or a
                 demoboard bridge.

The register map is the one in mom/rtl/hydra_tt_regs.sv, and
the encoding functions below are the ones tb_fpga_harness.sv exercises. The
transport is deliberately separable: SerialTransport talks to the FPGA
harness; anything with an xfer(bytes) -> bytes method can take its place.

  python3 hydra_host.py --port /dev/ttyUSB0 id
  python3 hydra_host.py --port /dev/ttyUSB0 selftest
  python3 hydra_host.py --port COM8 --baud 115200 calibrate --slow-us 200 -n 60

selftest runs the same three things the simulation does, on hardware:
the roofline crossover, a parameter retune that moves the decision, and the
calibration loop closing. If those three pass on a board, the FPGA image is
doing what the simulation said it does.
"""
import argparse
import sys
import time

# ---------------------------------------------------------------- registers
A_ID, A_WD, A_CTRL, A_ACTION, A_COMP, A_STATUS = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05
A_RESULT, A_LASTWD, A_CALUPD, A_BUSY, A_FENCE, A_PARAM = 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B
A_GLOBAL, A_INFO = 0x0C, 0x0D
LEN = {A_ID: 4, A_WD: 16, A_CTRL: 1, A_ACTION: 1, A_COMP: 1, A_STATUS: 2,
       A_RESULT: 6, A_LASTWD: 16, A_CALUPD: 2, A_BUSY: 2, A_FENCE: 1,
       A_PARAM: 6, A_GLOBAL: 2, A_INFO: 1}
ST = dict(ready=15, busy=14, pending=13, wd_ok=12, disp=11, unsupp=10, stale=9,
          frame_err=8, go_err=7, fence=6, param_lock=5, hold=4,
          cal_freeze=3, cal_reset=2)
ENG = {0: "CPU", 1: "SIMD", 2: "TPU", 3: "NTT", 4: "CRYPTO"}
OPC_GEMM, DT_INT8, LAT_BALANCED, PWR_BALANCED = 3, 0, 1, 1


def descriptor(op_class=OPC_GEMM, dtype=DT_INT8, lat=LAT_BALANCED, pwr=PWR_BALANCED,
               m=8, n=8, k=8, nbytes=192, src_loc=0, tag=0):
    """work_desc_t, first field most significant (mom_pkg.sv)."""
    fields = [(op_class, 4), (dtype, 3), (lat, 2), (pwr, 2), (m, 16), (n, 16),
              (k, 16), (nbytes, 24), (src_loc, 2), (tag, 8), (0, 35)]
    assert sum(w for _, w in fields) == 128
    d = 0
    for v, w in fields:
        d = (d << w) | (v & ((1 << w) - 1))
    return d


def param_row(p_peak, t_setup, bw, eps, dtype_msk, opc_msk):
    """eng_param_t, packed as mom_param_rom.sv packs its defaults."""
    return ((p_peak << 39) | (t_setup << 27) | (bw << 23) | (eps << 15)
            | (dtype_msk << 9) | opc_msk)


DEF = {  # the reset defaults, copied from mom_param_rom.sv
    "CPU": param_row(0, 0, 2, 80, 0b011111, 0b111111111),
    "SIMD": param_row(3, 8, 4, 20, 0b011111, 0b000111110),
    "TPU": param_row(7, 64, 5, 2, 0b000011, 0b000011000),
    "NTT": param_row(5, 32, 4, 8, 0b100100, 0b001100000),
    "CRYPTO": param_row(4, 16, 4, 4, 0b000100, 0b110000000),
}


# ------------------------------------------------------------------ framing
def frame_bytes(addr, read, data=None, nbytes=None):
    """The SPI byte sequence for one register access."""
    n = LEN.get(addr, 1) if nbytes is None else nbytes
    if read:
        return bytes([0x80 | addr]) + bytes(n)
    return bytes([addr & 0x7F]) + bytes((data >> (8 * (n - 1 - i))) & 0xFF for i in range(n))


def uart_frame(payload):
    """Harness command A5: an SPI frame of len(payload) bytes."""
    if len(payload) > 32:
        raise ValueError("the harness accepts at most 32 bytes per frame")
    return bytes([0xA5, len(payload)]) + payload


# ---------------------------------------------------------------- transport
class SerialTransport:
    def __init__(self, port, baud=115200, timeout=2.0):
        import serial                      # pyserial, only needed for hardware
        self.s = serial.Serial(port, baud, timeout=timeout)
        self.s.reset_input_buffer()

    def _read(self, n):
        b = self.s.read(n)
        if len(b) != n:
            raise IOError(f"timeout: wanted {n} bytes, got {len(b)!r}")
        return b

    def xfer(self, payload):
        self.s.write(uart_frame(payload))
        hdr = self._read(2)
        if hdr[0] != 0x5A or hdr[1] != len(payload):
            raise IOError(f"bad reply header {hdr.hex()}")
        return self._read(len(payload))

    def reset_tile(self, register_mode=True):
        self.s.write(bytes([0xC3, 1 if register_mode else 0]))
        r = self._read(2)
        if r[0] != 0x3C:
            raise IOError(f"bad reset reply {r.hex()}")

    def pins(self, value, pulse=False):
        self.s.write(bytes([0x97 if pulse else 0x96, value]))
        r = self._read(3)
        if r[0] != 0x69:
            raise IOError(f"bad pin reply {r.hex()}")
        return r[1], r[2]


class Tile:
    def __init__(self, t):
        self.t = t

    def read(self, addr, nbytes=None):
        n = LEN.get(addr, 1) if nbytes is None else nbytes
        r = self.t.xfer(frame_bytes(addr, True, nbytes=n))
        return int.from_bytes(r[1:], "big"), r[0]

    def write(self, addr, value, nbytes=None):
        self.t.xfer(frame_bytes(addr, False, value, nbytes))

    def status(self):
        v, _ = self.read(A_STATUS)
        return {k: (v >> b) & 1 for k, b in ST.items()}

    def result(self):
        v, _ = self.read(A_RESULT)
        return dict(engine=(v >> 45) & 7, tag=(v >> 41) & 0xF,
                    margin=(v >> 8) & 0xFFFFFFFF, err_tag=v & 0xFF)

    def dispatch(self, desc):
        self.write(A_WD, desc)
        self.write(A_ACTION, 0x01)
        st = self.status()
        if not st["wd_ok"]:
            raise IOError("descriptor was not accepted (WD_OK low)")
        return st, self.result()

    def complete(self, tag):
        self.write(A_COMP, tag & 0xF)

    def set_param(self, engine, row):
        self.write(A_PARAM, (engine << 43) | row)


# ------------------------------------------------------------------ commands
def cmd_id(tile, a):
    ident, first = tile.read(A_ID)
    print(f"ID {ident:#010x} ({'HYM2 ok' if ident == 0x48594D32 else 'UNEXPECTED'})"
          f"  NTAG {tile.read(A_INFO)[0]}  status byte {first:#04x}")
    print("status:", {k: v for k, v in tile.status().items() if v})


def cmd_dispatch(tile, a):
    st, r = tile.dispatch(descriptor(m=a.m, n=a.n, k=a.k, nbytes=a.bytes))
    print(f"{a.m}x{a.n}x{a.k} -> {ENG[r['engine']]} tag {r['tag']} margin {r['margin']}")
    tile.complete(r["tag"])


def cmd_selftest(tile, a):
    ok = True
    ident, _ = tile.read(A_ID)
    print(f"1. identity      {ident:#010x} {'ok' if ident == 0x48594D32 else 'FAIL'}")
    ok &= ident == 0x48594D32

    _, s = tile.dispatch(descriptor(m=4, n=4, k=4, nbytes=48))
    tile.complete(s["tag"])
    _, l = tile.dispatch(descriptor(m=8, n=8, k=8, nbytes=192))
    tile.complete(l["tag"])
    cross = s["engine"] != l["engine"]
    print(f"2. crossover     4x4x4 -> {ENG[s['engine']]} (margin {s['margin']}), "
          f"8x8x8 -> {ENG[l['engine']]} (margin {l['margin']}) "
          f"{'ok' if cross else 'FAIL: same engine'}")
    ok &= cross

    tile.set_param(2, param_row(7, 4000, 5, 2, 0b000011, 0b000011000))
    _, r = tile.dispatch(descriptor(m=8, n=8, k=8, nbytes=192))
    tile.complete(r["tag"])
    moved = r["engine"] != l["engine"]
    print(f"3. retune        TPU setup 64 -> 4000 moves 8x8x8 to {ENG[r['engine']]} "
          f"{'ok' if moved else 'FAIL: decision did not move'}")
    ok &= moved
    tile.set_param(2, DEF["TPU"])

    print("4. calibration   ", end="", flush=True)
    moved, trace = calibration_loop(tile, a.slow_us if hasattr(a, "slow_us") else 200, 80)
    print(f"decision left the TPU after {len(trace)} slow completions "
          f"{'ok' if moved else 'FAIL'}")
    ok &= moved
    print("SELFTEST", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def calibration_loop(tile, slow_us, n):
    first, trace = None, []
    for _ in range(n):
        _, r = tile.dispatch(descriptor(m=8, n=8, k=8, nbytes=192))
        trace.append((ENG[r["engine"]], r["margin"]))
        if first is None:
            first = r["engine"]
        if r["engine"] != first:
            tile.complete(r["tag"])
            return True, trace
        time.sleep(slow_us / 1e6)
        tile.complete(r["tag"])
    return False, trace


def cmd_calibrate(tile, a):
    moved, trace = calibration_loop(tile, a.slow_us, a.n)
    for i, (e, m) in enumerate(trace):
        print(f"  {i:3d} {e:6s} margin {m}")
    print(f"updates {tile.read(A_CALUPD)[0]}; "
          f"{'decision moved' if moved else 'decision did not move'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True, help="/dev/ttyUSB0, or COM8 on Windows")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-reset", action="store_true",
                    help="skip the tile reset that selects the register personality")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("id").set_defaults(fn=cmd_id)
    d = sub.add_parser("dispatch")
    d.add_argument("-m", type=int, default=8)
    d.add_argument("-n", type=int, default=8)
    d.add_argument("-k", type=int, default=8)
    d.add_argument("--bytes", type=int, default=192)
    d.set_defaults(fn=cmd_dispatch)
    s = sub.add_parser("selftest")
    s.add_argument("--slow-us", type=int, default=200)
    s.set_defaults(fn=cmd_selftest)
    c = sub.add_parser("calibrate")
    c.add_argument("--slow-us", type=int, default=200)
    c.add_argument("-n", type=int, default=80)
    c.set_defaults(fn=cmd_calibrate)
    a = ap.parse_args()

    tr = SerialTransport(a.port, a.baud)
    if not a.no_reset:
        tr.reset_tile(register_mode=True)
    sys.exit(a.fn(Tile(tr), a) or 0)


if __name__ == "__main__":
    main()

# ---------------------------------------------------------------------------
# Scratchpad access (bridge commands 'M' and 'R')
# ---------------------------------------------------------------------------
def mem_write(port, bank, addr, data):
    """Write one 32-bit word into an operand bank. Returns True on ack."""
    frame = bytes([0x4D, bank & 3, (addr >> 8) & 0xFF, addr & 0xFF,
                   (data >> 24) & 0xFF, (data >> 16) & 0xFF,
                   (data >> 8) & 0xFF, data & 0xFF])
    port.write(frame)
    r = port.read(2)
    return len(r) == 2 and r[0] == 0xB2


def mem_read(port, addr):
    """Read one word back. Returns the value, or None if the board did not answer."""
    port.write(bytes([0x52, (addr >> 8) & 0xFF, addr & 0xFF]))
    r = port.read(5)
    if len(r) != 5 or r[0] != 0xA6:
        return None
    return (r[1] << 24) | (r[2] << 16) | (r[3] << 8) | r[4]


def pack_lanes(values):
    """Four signed bytes into one word, lane 0 in the low byte -- the layout
    mem/rtl/hydra_dma_agen.sv documents."""
    w = 0
    for i, v in enumerate(values[:4]):
        w |= (int(v) & 0xFF) << (8 * i)
    return w


def load_gemm(port, a, b, base=0):
    """Write A and B in the bank layout the streamer expects.

    a is M x K, b is K x N, both lists of lists of small integers. Lanes
    past the tile are zeroed here, because the engine has no idea which
    lanes are inside a tile and should not need to.
    """
    m, k = len(a), len(a[0])
    n = len(b[0])
    for t in range(k):
        acol = [a[i][t] if i < m else 0 for i in range(4)]
        brow = [b[t][j] if j < n else 0 for j in range(4)]
        if not mem_write(port, 0, base + t, pack_lanes(acol)):
            raise RuntimeError(f"A bank write at {base + t} was not acknowledged")
        if not mem_write(port, 1, base + t, pack_lanes(brow)):
            raise RuntimeError(f"B bank write at {base + t} was not acknowledged")
    return m, n, k


def gemm_descriptor(m, n, k, base_a=0, base_b=0, base_c=0):
    """A GEMM descriptor carrying the three bank addresses in reserved bits."""
    # descriptor() already returns an integer here, not bytes; converting
    # it again raised a TypeError the moment the function was first called.
    v = descriptor(m=m, n=n, k=k, nbytes=0)
    if isinstance(v, (bytes, bytearray)):
        v = int.from_bytes(v, "big")
    v |= (base_a & 0x3FF) << 3
    v |= (base_b & 0x3FF) << 13
    v |= (base_c & 0x3FF) << 23
    return v.to_bytes(16, "big")

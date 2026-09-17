#!/usr/bin/env python3
"""
pllcalc.py -- PLL parameters for every FPGA family the FPGA target supports.

RULE: never exceed the requested frequency. The request is the frequency the
design was timed at; overshooting it by 0.3% to get a "closer" match is how a
build that passed timing fails on the bench. We pick the highest achievable
frequency <= target, prefer an exact match, and break ties by putting the VCO
nearest the middle of its range (least jitter-sensitive, most margin).

If the oscillator already equals the target, no PLL is instantiated.

Limits and their sources (checked against the reference tools where those
exist -- see test_pllcalc.py, which runs icepll, ecppll, and gowin_pll):
  ice40   : Lattice iCE40 PLL user guide; icepll (icestorm)
  ecp5    : prjtrellis ecppll
  xilinx7 : 7-series clocking guide (UG472), -1 speed grade, integer M/O only
  gowin   : Apicula gowin_pll device table
  intel   : altpll M/D ratio only -- Quartus picks the VCO. NOT verifiable in
            this environment; Quartus reports the achieved frequency.
"""
import math
import sys

MHZ = 1_000_000

LIMITS = {
    "ice40": dict(fin=(10, 133), pfd=(10, 133), vco=(533, 1066), fout=(16, 275)),
    "ecp5": dict(fin=(8, 400), pfd=(3.125, 400), vco=(400, 800), fout=(10, 400)),
    "xilinx7": dict(fin=(10, 800), pfd=(10, 450), vco=(600, 1200), fout=(4.69, 800)),
    # Apicula device table (GW2A-18 C8/I7 is the Tang Nano 20K / Primer 20K part)
    "gowin:GW2A-18 C8/I7": dict(fin=(3, 500), pfd=(3, 500), vco=(500, 1250), fout=(3.90625, 625)),
    "gowin:GW1N-9 C6/I5": dict(fin=(3, 400), pfd=(3, 400), vco=(400, 1200), fout=(3.125, 600)),
}

GOWIN_ODIV = (2, 4, 8, 16, 32, 48, 64, 80, 96, 112, 128)


class PllError(Exception):
    pass


def _within(x, rng):
    return rng[0] - 1e-9 <= x <= rng[1] + 1e-9


def _pick(cands, target, vco_mid, floor=None):
    """cands: list of (fout, vco, params). Highest fout <= target wins."""
    ok = [c for c in cands if c[0] <= target + 1e-9]
    if not ok:
        hint = ""
        if floor is not None:
            hint = (f"; the closest settings are below this family's {floor} MHz "
                    f"output floor. icepll will happily return such a value "
                    f"(15.938 MHz for a 16 MHz request from 12 MHz); running the "
                    f"PLL out of its datasheet range is not something this flow "
                    f"does silently. Ask for a frequency the part can make, or "
                    f"drive the design from the oscillator and divide with a "
                    f"clock enable inside it")
        raise PllError(f"no PLL setting at or below {target:.6f} MHz{hint}")
    best = max(c[0] for c in ok)
    tied = [c for c in ok if abs(c[0] - best) < 1e-9]
    return min(tied, key=lambda c: abs(c[1] - vco_mid))


def ice40(fin, target):
    L = LIMITS["ice40"]
    cands = []
    for divr in range(16):
        pfd = fin / (divr + 1)
        if not _within(pfd, L["pfd"]):
            continue
        for divf in range(128):
            vco = pfd * (divf + 1)
            if not _within(vco, L["vco"]):
                continue
            for divq in range(1, 7):
                fout = vco / (1 << divq)
                if _within(fout, L["fout"]):
                    cands.append((fout, vco, dict(DIVR=divr, DIVF=divf, DIVQ=divq, pfd=pfd)))
    fout, vco, p = _pick(cands, target, sum(L["vco"]) / 2, floor=L["fout"][0])
    pfd = p.pop("pfd")
    # Filter range as icepll computes it.
    fr = 1 if pfd < 17 else 2 if pfd < 26 else 3 if pfd < 44 else 4 if pfd < 66 else 5 if pfd < 101 else 6
    p["FILTER_RANGE"] = fr
    return dict(vendor="ice40", fout=fout, vco=vco, pfd=pfd, params=p)


def ecp5(fin, target):
    L = LIMITS["ecp5"]
    cands = []
    for ref in range(1, 129):
        pfd = fin / ref
        if not _within(pfd, L["pfd"]):
            continue
        for fb in range(1, 81):
            fout = pfd * fb
            if not _within(fout, L["fout"]):
                continue
            for op in range(1, 129):
                vco = fout * op
                if _within(vco, L["vco"]):
                    cands.append((fout, vco, dict(CLKI_DIV=ref, CLKFB_DIV=fb,
                                                  CLKOP_DIV=op, CLKOP_CPHASE=op - 1)))
    fout, vco, p = _pick(cands, target, 600.0)
    return dict(vendor="ecp5", fout=fout, vco=vco, pfd=fin / p["CLKI_DIV"], params=p)


def xilinx7(fin, target):
    L = LIMITS["xilinx7"]
    cands = []
    for d in range(1, 107):
        pfd = fin / d
        if not _within(pfd, L["pfd"]):
            continue
        for m in range(2, 65):
            vco = pfd * m
            if not _within(vco, L["vco"]):
                continue
            for o in range(1, 129):
                fout = vco / o
                if _within(fout, L["fout"]):
                    cands.append((fout, vco, dict(DIVCLK_DIVIDE=d, CLKFBOUT_MULT_F=m,
                                                  CLKOUT0_DIVIDE_F=o)))
    fout, vco, p = _pick(cands, target, sum(L["vco"]) / 2)
    p["CLKIN1_PERIOD"] = round(1000.0 / fin, 3)
    return dict(vendor="xilinx7", fout=fout, vco=vco, pfd=fin / p["DIVCLK_DIVIDE"], params=p)


def gowin(fin, target, device="GW2A-18 C8/I7"):
    key = "gowin:" + device
    if key not in LIMITS:
        raise PllError(f"no Gowin limits for device {device!r}; add them from Apicula's table")
    L = LIMITS[key]
    cands = []
    for idiv in range(1, 65):
        pfd = fin / idiv
        if not _within(pfd, L["pfd"]):
            continue
        for fbdiv in range(1, 65):
            fout = pfd * fbdiv
            if not _within(fout, L["fout"]):
                continue
            for odiv in GOWIN_ODIV:
                vco = fout * odiv
                if _within(vco, L["vco"]):
                    cands.append((fout, vco, dict(IDIV_SEL=idiv - 1, FBDIV_SEL=fbdiv - 1,
                                                  ODIV_SEL=odiv)))
    fout, vco, p = _pick(cands, target, sum(L["vco"]) / 2)
    p["FCLKIN"] = f"{fin:g}"
    p["DEVICE"] = device.split()[0]
    return dict(vendor="gowin", fout=fout, vco=vco, pfd=fin / (p["IDIV_SEL"] + 1), params=p)


def intel(fin, target):
    best = None
    for d in range(1, 65):
        for m in range(1, 65):
            f = fin * m / d
            if f <= target + 1e-9 and (best is None or f > best[0] + 1e-9):
                best = (f, m, d)
    if best is None:
        raise PllError("no altpll ratio found")
    f, m, d = best
    g = math.gcd(m, d)
    return dict(vendor="intel", fout=f, vco=None, pfd=None,
                params=dict(clk0_multiply_by=m // g, clk0_divide_by=d // g,
                            inclk0_input_frequency=int(round(1e6 / fin))),  # ps
                note="VCO chosen by Quartus; confirm achieved frequency in the fit report")


def solve(vendor, fin_hz, target_hz, device=None):
    fin, target = fin_hz / MHZ, target_hz / MHZ
    if target <= 0:
        raise PllError("target must be positive")
    if abs(fin - target) < 1e-9:
        return dict(vendor=vendor, bypass=True, fout=fin, params={})
    if vendor == "generic":
        if target < fin:
            raise PllError(f"generic build cannot divide {fin} MHz to {target} MHz; "
                           "pick a vendor or set sys_hz to the oscillator frequency")
        return dict(vendor=vendor, bypass=True, fout=fin, params={})
    fn = {"ice40": ice40, "ecp5": ecp5, "xilinx7": xilinx7, "intel": intel}.get(vendor)
    if vendor == "gowin":
        r = gowin(fin, target, device or "GW2A-18 C8/I7")
    elif fn is None:
        raise PllError(f"unknown vendor {vendor!r}")
    else:
        r = fn(fin, target)
    r["bypass"] = False
    return r


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("usage: pllcalc.py <vendor> <fin_hz> <target_hz> [device]")
        sys.exit(2)
    res = solve(sys.argv[1], float(sys.argv[2]), float(sys.argv[3]),
                sys.argv[4] if len(sys.argv) > 4 else None)
    print(res)

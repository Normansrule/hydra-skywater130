#!/usr/bin/env python3
"""
test_pllcalc.py -- check the PLL solver against the vendors' own calculators.

The reference tools (icepll from icestorm, ecppll from prjtrellis, gowin_pll
from Apicula) are independent implementations of the same arithmetic, which
is what makes them worth comparing to. They are not authorities on our
policy, though: they pick the CLOSEST frequency, we pick the highest one
at or below the request. So the checks are:

  1. the parameters we emit reproduce the frequency we claim, by recomputing
     from the datasheet equations here rather than trusting the solver;
  2. every limit (phase detector, VCO, output) is respected;
  3. we never exceed the request;
  4. where the reference tool lands at or below the request too, we are at
     least as close as it is.

Run: python3 -m pytest tools/test_pllcalc.py -q
"""
import re
import shutil
import subprocess

import pytest

import pllcalc

MHZ = 1e6


def icepll(fin, fout):
    out = subprocess.run(["icepll", "-i", str(fin), "-o", str(fout)],
                         capture_output=True, text=True).stdout
    # icepll prints F_PLLOUT twice: requested, then achieved. Take the
    # achieved one -- matching the first line silently compares the tool's
    # answer with our own request.
    d = lambda k: int(re.search(rf"{k}:\s+(\d+)", out).group(1))
    achieved = float(re.search(r"F_PLLOUT:\s+([\d.]+) MHz \(achieved\)", out).group(1))
    return dict(fout=achieved, divr=d("DIVR"), divf=d("DIVF"), divq=d("DIVQ"),
                fr=d("FILTER_RANGE"))


def ecppll(fin, fout):
    out = subprocess.run(["ecppll", "-i", str(fin), "-o", str(fout)],
                         capture_output=True, text=True).stdout
    return dict(fout=float(re.search(r"clkout0 frequency: ([\d.]+)", out).group(1)),
                ref=int(re.search(r"Refclk divisor: (\d+)", out).group(1)),
                fb=int(re.search(r"Feedback divisor: (\d+)", out).group(1)),
                op=int(re.search(r"clkout0 divisor: (\d+)", out).group(1)))


def gowinpll(fin, fout, dev="GW2AR-LV18QN88C8/I7"):
    out = subprocess.run(["gowin_pll", "-i", str(fin), "-o", str(fout), "-d", dev],
                         capture_output=True, text=True).stdout
    return dict(fout=float(re.search(r"Achieved output frequency:\s+([\d.]+)", out).group(1)))


ICE40_CASES = [(12, 30), (12, 24), (12, 48), (12, 20), (100, 50), (25, 100)]
ECP5_CASES = [(25, 50), (25, 12.5), (25, 100), (12, 40), (27, 75)]
XILINX_CASES = [(100, 25), (100, 50), (100, 10), (200, 100), (100, 12.5)]
GOWIN_CASES = [(27, 27 / 2), (27, 24), (27, 54), (27, 18)]


@pytest.mark.parametrize("fin,target", ICE40_CASES)
def test_ice40(fin, target):
    r = pllcalc.solve("ice40", fin * MHZ, target * MHZ)
    p = r["params"]
    pfd = fin / (p["DIVR"] + 1)
    vco = pfd * (p["DIVF"] + 1)
    assert r["fout"] == pytest.approx(vco / (1 << p["DIVQ"]))
    assert 10 <= pfd <= 133 and 533 <= vco <= 1066 and 16 <= r["fout"] <= 275
    assert r["fout"] <= target + 1e-9
    ref = icepll(fin, target)
    assert ref["fr"] == p["FILTER_RANGE"] or ref["fout"] != r["fout"]
    if ref["fout"] <= target + 1e-9:
        assert target - r["fout"] <= target - ref["fout"] + 1e-9


@pytest.mark.parametrize("fin,target", ECP5_CASES)
def test_ecp5(fin, target):
    r = pllcalc.solve("ecp5", fin * MHZ, target * MHZ)
    p = r["params"]
    pfd = fin / p["CLKI_DIV"]
    fout = pfd * p["CLKFB_DIV"]
    vco = fout * p["CLKOP_DIV"]
    assert r["fout"] == pytest.approx(fout)
    assert p["CLKOP_CPHASE"] == p["CLKOP_DIV"] - 1
    assert 3.125 <= pfd <= 400 and 400 <= vco <= 800 and 10 <= fout <= 400
    assert r["fout"] <= target + 1e-9
    ref = ecppll(fin, target)
    if ref["fout"] <= target + 1e-9:
        assert target - r["fout"] <= target - ref["fout"] + 1e-9


@pytest.mark.parametrize("fin,target", XILINX_CASES)
def test_xilinx7(fin, target):
    # No reference tool here: Vivado is not in this environment. The datasheet
    # equations and limits are checked instead, and the fit report is the
    # authority on the board.
    r = pllcalc.solve("xilinx7", fin * MHZ, target * MHZ)
    p = r["params"]
    pfd = fin / p["DIVCLK_DIVIDE"]
    vco = pfd * p["CLKFBOUT_MULT_F"]
    assert r["fout"] == pytest.approx(vco / p["CLKOUT0_DIVIDE_F"])
    assert 10 <= pfd <= 450 and 600 <= vco <= 1200
    assert 2 <= p["CLKFBOUT_MULT_F"] <= 64 and 1 <= p["CLKOUT0_DIVIDE_F"] <= 128
    assert r["fout"] <= target + 1e-9


@pytest.mark.parametrize("fin,target", GOWIN_CASES)
def test_gowin(fin, target):
    r = pllcalc.solve("gowin", fin * MHZ, target * MHZ, "GW2A-18 C8/I7")
    p = r["params"]
    pfd = fin / (p["IDIV_SEL"] + 1)
    fout = pfd * (p["FBDIV_SEL"] + 1)
    vco = fout * p["ODIV_SEL"]
    assert r["fout"] == pytest.approx(fout)
    assert 3 <= pfd <= 500 and 500 <= vco <= 1250
    assert p["ODIV_SEL"] in pllcalc.GOWIN_ODIV
    assert r["fout"] <= target + 1e-9
    ref = gowinpll(fin, target)
    if ref["fout"] <= target + 1e-9:
        assert target - r["fout"] <= target - ref["fout"] + 1e-9


def test_never_exceeds_the_request():
    """The policy that matters: a solver that rounds up hands you a build that
    passed timing at a frequency the board does not run at."""
    for vendor, fin in (("ice40", 12), ("ecp5", 25), ("xilinx7", 100), ("gowin", 27)):
        for target in (17.3, 33.7, 41.1, 61.9):
            r = pllcalc.solve(vendor, fin * MHZ, target * MHZ)
            assert r["fout"] <= target + 1e-9, (vendor, target, r)


def test_equal_frequency_needs_no_pll():
    r = pllcalc.solve("ecp5", 25 * MHZ, 25 * MHZ)
    assert r["bypass"] and r["params"] == {}


def test_impossible_request_is_an_error():
    with pytest.raises(pllcalc.PllError):
        pllcalc.solve("ice40", 12 * MHZ, 1 * MHZ)      # below the iCE40 output floor
    with pytest.raises(pllcalc.PllError):
        pllcalc.solve("generic", 25 * MHZ, 10 * MHZ)   # no PLL to divide with


def test_ice40_output_floor_is_respected():
    """From 12 MHz the phase detector must run at 12 MHz, so the VCO is a
    multiple of 12 and no setting lands on 16 MHz exactly. icepll answers
    15.938 MHz, below the family's 16 MHz output floor. We refuse instead,
    with an error that says what to do about it."""
    ref = icepll(12, 16)
    assert ref["fout"] < 16.0
    with pytest.raises(pllcalc.PllError) as e:
        pllcalc.solve("ice40", 12 * MHZ, 16 * MHZ)
    assert "output floor" in str(e.value)


def test_reference_tools_are_present():
    """If a reference tool is missing the comparisons above silently become
    weaker, so say so out loud."""
    missing = [t for t in ("icepll", "ecppll", "gowin_pll") if shutil.which(t) is None]
    assert not missing, f"reference calculators missing: {missing}"

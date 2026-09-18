#!/usr/bin/env python3
"""
capacity.py -- will this block fit on that board?

The conversion factors here are MEASURED on this project's own RTL, not taken
from a vendor's marketing table:

  the TT-A v2 tile, one design, three mappings
    sky130 standard cells   28,183 cells / 194,647 um2   (yosys + abc)
    Lattice ECP5 LUT4       14,360                        (yosys + nextpnr)
    Xilinx 7-series LUT6    see XILINX_LUT6 below         (yosys synth_xilinx)

That gives 0.51 ECP5 LUT4 per sky130 cell for logic of this shape: control,
comparators, small multipliers. It is a RATIO FROM ONE DESIGN. Wide datapath
logic (the P-256 units, the systolic array) maps more densely, and deep
register files map worse unless they become block RAM. Treat everything below
as an order-of-magnitude answer that tells you which board to buy, not a
utilisation report.

Block sizes come from the HYDRA-130 session-178 handoff, where they were
measured by real place and route. Expansion sizes are ESTIMATES and marked.

Usage: python3 tools/capacity.py [--md]
"""
import argparse

# --- measured, this project -------------------------------------------------
TILE_CELLS = 28_183
TILE_ECP5_LUT4 = 14_360
XILINX_LUT6 = 7_539          # measured: yosys synth_xilinx -family xc7 on the v2 tile
LUT4_PER_CELL = TILE_ECP5_LUT4 / TILE_CELLS

# --- boards, from their datasheets -----------------------------------------
BOARDS = [
    # name, LUTs, kind, note
    ("iCE40 UP5K (iCEBreaker)", 5_280, "LUT4", "$69"),
    ("Gowin GW2AR-18 (Tang Nano 20K)", 20_736, "LUT4", "$30, Amazon"),
    ("Artix-7 35T (Cmod A7)", 20_800, "LUT6", "$99, DigiKey"),
    ("ECP5-85F (ECP5 Evaluation Board)", 83_640, "LUT4", "$99-159, DigiKey"),
    ("Artix-7 100T (Arty A7-100T)", 63_400, "LUT6", "~$299"),
    ("Artix-7 200T (Nexys Video)", 134_600, "LUT6", "~$599"),
    ("Kintex-7 325T (Genesys 2)", 203_800, "LUT6", "~$1,200"),
]

# --- what exists today, measured by place and route (handoff, session 178) --
BLOCKS = [
    # name, sky130 cells, measured?, note
    ("ecdsa_top", 188_028, True, "P-256 sign and verify, shared units"),
    ("tpu_top", 86_591, True, "systolic array"),
    ("mom_top (as the v2 tile)", 28_183, True, "the dispatcher, measured three ways"),
    ("core_pipe", 24_491, True, "pipelined RISC-V core"),
    ("core_mini", 9_923, True, "small RISC-V core"),
    ("axis blocks (qenc, enc_theta, adc_capture, pwm_gen)", 2_600, True, "~650 cells each"),
    ("data RAM (flop array)", 135_000, False,
     "0.93 mm2 of flops. On an FPGA this becomes block RAM and costs ~0 LUTs"),
]

# --- the roadmap, estimated -------------------------------------------------
# basis: comparable blocks in this project, or published open cores.
EXPANSIONS = [
    # section, name, cells, basis
    ("finish what is half-built", "SHE CMAC path", 12_000,
     "AES core exists; a CMAC wrapper plus the gate-level tag compare"),
    ("finish what is half-built", "trng_source + trng_pool", 6_000,
     "ring oscillators, conditioning, FIFO. trng_health already exists"),
    ("finish what is half-built", "USB protocol engine + CDC", 20_000,
     "typical open full-speed device core; the wire layer is done"),
    ("finish what is half-built", "engine crossbar (MOM to the engines)", 8_000,
     "same arbitration shape as ecdsa_top's, five ports"),
    ("finish what is half-built", "firmware layer", 0, "software, no gates"),

    ("functional safety", "RAM ECC (SECDED) + bus fault unit", 10_000,
     "encoder/decoder per port plus a trap unit"),
    ("functional safety", "dual-core lockstep", 25_000,
     "a second core_pipe plus comparator and delay line"),
    ("functional safety", "RISC-V PMP", 8_000, "8-16 regions, address comparators"),
    ("functional safety", "voltage / temperature / glitch monitors", 4_000,
     "mostly analog; the digital side is small"),
    ("functional safety", "watchdog to safe state", 1_000,
     "wiring the existing watchdog into pwm_gen's fault input"),

    ("robotics I/O", "multi-axis motor control, per extra axis", 3_000,
     "replication of the verified axis blocks plus arbitration"),
    ("robotics I/O", "  6 axes", 18_000, "6 x the above"),
    ("robotics I/O", "  20 axes (a humanoid)", 60_000, "20 x the above"),
    ("robotics I/O", "CAN-FD controller", 15_000, "classic controller plus bit-rate switching"),
    ("robotics I/O", "SecOC (authenticated frames)", 6_000, "reuses the HMAC core"),
    ("robotics I/O", "synchronised sensor capture", 4_000, "timestamp counter, trigger/capture"),
    ("robotics I/O", "SPI slave / host offload port", 5_000, "register file plus DMA-lite"),
    ("robotics I/O", "absolute encoders (BiSS-C or SSI)", 6_000, "serial protocol plus CRC"),

    ("security depth", "authenticated debug unlock", 10_000,
     "challenge-response against the PUF key, lifecycle state machine"),
    ("security depth", "measured boot and attestation", 8_000,
     "measurement registers on top of rot_boot; signing reuses ECDSA"),
    ("security depth", "ML-KEM (Kyber) on the NTT", 40_000,
     "keygen/encaps/decaps control plus sampling; the NTT already exists"),
    ("security depth", "PUF key provisioning", 5_000, "derivation into a keystore slot"),
    ("security depth", "fault-injection hardening on the signature path", 30_000,
     "redundant computation: roughly a second copy of the critical datapath"),

    ("bigger swings", "SRAM macro instead of the flop array", -135_000,
     "removes 0.93 mm2 of flops from the die (no FPGA effect: already block RAM)"),
    ("bigger swings", "camera interface (DVP)", 8_000, "MIPI CSI-2 is not tractable at 130 nm"),
    ("bigger swings", "Ethernet / TSN MAC", 60_000, "a very large piece of work"),
    ("bigger swings", "GPU (already in the design, size not in the handoff)", 80_000,
     "GUESS: no PAR number was given for it. Replace this with the real one"),
]


def lut4(cells):
    return cells * LUT4_PER_CELL


def lut6(cells):
    # Measured on the tile: LUT6 devices need fewer LUTs for the same logic.
    return cells * (XILINX_LUT6 / TILE_CELLS)


def fits(cells, board):
    name, cap, kind, _ = board
    need = lut4(cells) if kind == "LUT4" else lut6(cells)
    return need, need / cap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", action="store_true", help="markdown for docs/CAPACITY.md")
    a = ap.parse_args()

    ecp5 = next(b for b in BOARDS if b[0].startswith("ECP5-85F"))
    soc_cells = sum(c for _, c, _, note in BLOCKS if "block RAM" not in note)

    if a.md:
        print("| block | sky130 cells | ECP5-85F LUT4 | % of the board |")
        print("|---|---|---|---|")
        for name, cells, measured, _ in BLOCKS:
            need, frac = fits(cells, ecp5)
            mark = "" if measured else " (est)"
            print(f"| {name}{mark} | {cells:,} | {need:,.0f} | {100*frac:.0f}% |")
        print()
        print("| expansion | sky130 cells (est) | ECP5-85F LUT4 | fits beside the tile? |")
        print("|---|---|---|---|")
        for sect, name, cells, _ in EXPANSIONS:
            if cells <= 0:
                continue
            need, frac = fits(cells, ecp5)
            room = (ecp5[1] - TILE_ECP5_LUT4)
            print(f"| {name} | {cells:,} | {need:,.0f} | "
                  f"{'yes' if need < room else 'NO'} |")
    else:
        print(f"conversion: {LUT4_PER_CELL:.3f} ECP5 LUT4 per sky130 cell "
              f"(measured on the tile)")
        print(f"\nthe SoC as it stands: {soc_cells:,} cells "
              f"-> {lut4(soc_cells):,.0f} LUT4 / {lut6(soc_cells):,.0f} LUT6")
        print("\nboard verdicts for the whole SoC:")
        for b in BOARDS:
            need, frac = fits(soc_cells, b)
            print(f"  {b[0]:36s} {b[1]:>8,} {b[2]}  needs {100*frac:5.0f}%  "
                  f"{'fits' if frac < 0.8 else 'does NOT fit'}   {b[3]}")


if __name__ == "__main__":
    main()

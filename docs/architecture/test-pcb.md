# HYDRA-130 test board (planned)

**Status: PLANNED, not designed.** There is no HYDRA board: no schematic, no
layout, nothing fabricated. Every HYDRA image so far has run in simulation
only, and the FPGA images target third-party development boards (ULX3S,
ECP5 evaluation, Arty A7, Tang Nano 20K, Basys 3), none of which has run one
yet. This page proposes a custom test board for the SkyWater 130 OpenFrame
chip as a separate milestone, so the bring-up the simulations rehearse
(`make sky130`, `make sky130-mcu`, `make baremetal`) has hardware to run on.

## Why a board of our own

The chip's test flow already exists in simulation. A board would make the
same steps physical:

| step | simulated today by | what the board needs |
|---|---|---|
| clock and reset | `tb_openframe*` drive pad 0 (clock) and pad 1 (reset) | an oscillator into pad 0 with a footprint for a second frequency, a reset button and supervisor on pad 1, the connect strap on pad 2 as a jumper |
| scheduler over SPI | pads 3, 4, 5 (SCK, COPI, CSn) and 11 (CIPO) | a header to a USB-SPI bridge (an FT2232H, which also gives JTAG and a UART) |
| program load, secure boot, GPIO owner | the I2C target on pads 27 (SCL) and 28 (SDA), address 0x2A | pull-ups on SCL and SDA, a header for the same USB bridge or a Qwiic connector |
| the CPU's console | pad 29 with I2C OWNER[0] set: 8N1 UART | a test point and a route to the bridge's UART receive pin |
| the CPU's LEDs and buttons | pads 30 to 43 with OWNER[1] set | 14 LEDs with series resistors on a jumper block (so the pads can also be plain GPIO), two push buttons |
| the tile's other pins | the rest of pads 3 to 26, through the pad multiplexer | test points or a logic-analyser header |
| power | the padframe's supplies (`vccd1`, `vddio` and the others listed in `docs/pins.md`) | regulators and current-sense resistors on each rail, so power can be measured, not estimated |

A host script would run the same sequences as the testbenches:
`tools/hydra_host.py` for the scheduler, and an I2C equivalent of
`tb_openframe_mcu` for loading, booting and reading the console.

## What has to be known first (blocking)

- **The package.** `docs/pins.md` names pads, not package pins: no package
  is chosen and ChipFoundry's OpenFrame package pin map is not checked in
  this repository. The footprint and the pin-out wait for it.
- **Supply voltages and which domain powers the core.** `docs/pins.md`
  marks them as not verified against ChipFoundry's datasheet.
- **A signed-off chip.** The microcontroller core's sixth harden is clean
  except for hold at the fast corners (`docs/HANDOFF.md`); the full
  OpenFrame top has not been hardened.

## Proposed order

1. Bring up the FPGA images on one of the development boards first (the
   order `docs/architecture/heterogeneous-system.md` already gives), so
   the host software is proven on hardware before silicon.
2. Draw the schematic from `docs/pins.md` once the package is known, with
   a design-rule check in the PCB tool and a netlist check against the pin
   table generated from `sky130/rtl/hydra_openframe_top.sv`.
3. Lay out and order the board only after the chip is signed off and a
   shuttle date exists.

Nothing on this page is a result. When any part of it is done, it moves to
the evidence tables with the command or measurement that shows it.

# Reference library

Guides and specifications this project builds against, by topic. These are
links: none of them is copied into the repository, and the list records
where to look, not a claim that a page says what this project needs. When
a fact in `docs/tapeout/facts.json` comes from one of these projects, the
fact names the file and commit it was read from.

## Tiny Tapeout (the tile's target)

- Tiny Tapeout specifications (tile sizes, pins, clock, power): https://tinytapeout.com/specs/
- Guides (hardening, testing, the GDS action): https://tinytapeout.com/guides/
- The tooling this repository's hardening checkout uses (`tt/` submodule of
  `~/src/tinytapeout-hydra`): https://github.com/TinyTapeout/tt-support-tools.
  Its `tech/sky130A/tile_sizes.yaml`, `tech.py` and `docs/PINOUT.md` are
  read directly by `tools/tapeout_facts.py`.
- Breakout board for Tiny Tapeout chips: https://github.com/TinyTapeout/caravel-breakout-pcb

## SkyWater 130 and the OpenFrame chip

- SkyWater SKY130 PDK documentation: https://skywater-pdk.readthedocs.io
- open_pdks (builds the PDK this project uses; version in `$PDK_ROOT/.../sky130A/SOURCES`): https://github.com/RTimothyEdwards/open_pdks
- Caravel harness and padframes (chip_io, OpenFrame): https://github.com/efabless/caravel
- OpenRAM (the SRAM macros): https://github.com/VLSIDA/OpenRAM
- LibreLane (the flow): https://librelane.readthedocs.io
- OpenROAD (place and route, timing): https://openroad.readthedocs.io
- Magic and Netgen (DRC, extraction, LVS): http://opencircuitdesign.com/magic/ and http://opencircuitdesign.com/netgen/

## Smaller and other open processes

Tiny Tapeout's tooling already carries technology files for two more open
processes (`tt/tech/gf180mcuD`, `tt/tech/ihp-sg13g2`), the nearest step
from SKY130 for this design:

- GlobalFoundries 180MCU PDK: https://gf180mcu-pdk.readthedocs.io
- IHP SG13G2 (130 nm BiCMOS, 1.2 V core): https://github.com/IHP-GmbH/IHP-Open-PDK

Nodes below 130 nm have no open PDK that a shuttle accepts today; for those,
`docs/tapeout/README.md` lists what in this design is process-independent
and what would change.

## RISC-V SoC design and bring-up

- Chipyard (SoC generator, simulation, bare-metal flow): https://chipyard.readthedocs.io
- UC Berkeley EE290C Baremetal-IDE lab (the bare-metal flow `make baremetal` follows): https://ucb-ee290c.github.io/tutorials/baremetal-ide/Baremetal-IDE-Lab.html
- RISC-V External Debug Support specification (the debug plan): https://github.com/riscv/riscv-debug-spec

## FPGA (testing before silicon)

- Project Trellis (ECP5 bitstream documentation): https://github.com/YosysHQ/prjtrellis
- nextpnr (place and route for ECP5, iCE40, Gowin): https://github.com/YosysHQ/nextpnr
- Apicula (Gowin bitstreams, the Tang Nano 20K build): https://github.com/YosysHQ/apicula
- ULX3S board: https://github.com/emard/ulx3s
- openFPGALoader (programming every board here): https://github.com/trabucayre/openFPGALoader
- Digilent Basys 3 reference manual: https://digilent.com/reference/programmable-logic/basys-3/reference-manual

## Course and tapeout material from the owner

Uploaded to the project on 2026-11-15 (EECS 151 labs and homework, an
EECS 151 FPGA project, Rocket Chip and related tapeout notes). Not on the
development machine yet; it will be listed here, with what was taken from
it, once it is.

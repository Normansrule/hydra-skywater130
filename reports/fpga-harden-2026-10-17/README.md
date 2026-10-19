# FPGA place and route and tile harden, 2026-10-17

Archived from the owner's machine (WSL2 Ubuntu). Every number below is
copied from the log next to it; nothing is typed. Placed and routed is
not a board result: no image here has run on a board.

| image | Fmax (nextpnr) | requested | log |
|---|---|---|---|
| `ecp5-evn` | 39.12 MHz | 12.00 MHz | `ecp5-evn-pnr.log.gz` |
| `ecp5-evn-selftest` | 250.00 MHz | 12.00 MHz | `ecp5-evn-selftest-pnr.log.gz` |
| `ecp5-evn-sys` | 43.40 MHz | 12.00 MHz | `ecp5-evn-sys-pnr.log.gz` |
| `ecp5-evn-tpu` | 42.46 MHz | 12.00 MHz | `ecp5-evn-tpu-pnr.log.gz` |
| `ecp5-evn-two` | 41.94 MHz | 12.00 MHz | `ecp5-evn-two-pnr.log.gz` |
| `ecp5-evn-mem` | 42.14 MHz | 12.00 MHz | `ecp5-evn-mem-pnr.log.gz` |
| `ulx3s-85f` | 27.53 MHz | 12.50 MHz | `ulx3s-85f-pnr.log.gz` |

Tools: tools   sv2v v0.0.13 Yosys 0.52 (git sha1 fee39a3284c90249e1d9684cf6944ffbbcbb8f90) nextpnr-ecp5 -- Next Generation Place and Route (Version 0.9-3) 

Tile harden ladder: `harden-ladder-20261017-212105.log.gz` -- rung drive2
(v3.5) failed setup (-2.403 ns), rung buffers20 (v3.4 settings) signed off
clean, then tile-gl 21/21. The v3.4 numbers in docs/timing.json come from
`harden-ladder-20261017-115622-checks.out`.

v3.6 (rung realbuf2) signed off clean: `harden-ladder-20261017-223414-v3.6.log.gz`, `harden-ladder-20261017-223414-v3.6-checks.out`.
GPU engine synthesized for ECP5 with yosys 0.52 (synth_ecp5): `gpu-ecp5-yosys-stat.txt`.

v3.7 (same settings, netlist regenerated after the engine-count change): `harden-ladder-20261018-105631-v3.7.log.gz`, `harden-ladder-20261018-105631-v3.7-checks.out`. Its netlist is proved equivalent to v3.6's: `tile-netlist-equivalence-neng.log.gz` (7,060 of 7,060 equivalence cells proven).

v3.8 (eligibility input tied off, ABI version 2 on the chip): `harden-ladder-20261018-131019-v3.8.log.gz`, `harden-ladder-20261018-131019-v3.8-checks.out`; netlist equivalence to v3.7: `tile-netlist-equivalence-elig.log.gz` (7,132 of 7,132 proven).

v3.9 (slew repair margin 35%, logic as v3.8): `harden-ladder-20261018-170542-v3.9.log.gz`, `harden-ladder-20261018-170542-v3.9-checks.out`.

v3.10 (scheduler liveness fix, v3.6 settings): `harden-ladder-20261018-174736-v3.10.log.gz`, `harden-ladder-20261018-174736-v3.10-checks.out`; 22/22 on the netlist.

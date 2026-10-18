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

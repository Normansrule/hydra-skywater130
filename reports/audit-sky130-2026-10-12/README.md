# Evidence: SkyWater 130 audit, 2026-10-12

Logs from closing the *HYDRA SkyWater130: Full Engineering and Documentation
Audit* ([closure table](../../docs/audit/second-audit-closure.md#skywater-130-audit)),
with the tools in `tools.txt`. Simulation and formal only: no FPGA place and
route, and no board.

| file | what it shows |
|---|---|
| `verify_summary.log` | every PASS line of `make -k verify` (exit 0) |
| `ci_selftest.log` | 13 injected breaks all caught, 9 clean targets pass |
| `mom_mutate.log` | `make mom-mutate`: each fix from this audit put back, and its test fails (8 of 8) |
| `tile_mutate.log` | `tt/tile/test/mutate_sim.py` on the v3.1 tile |
| `before/model01_02_cost_cal.log` | cost normalisation up to 50 % low; calibration moving k the wrong way; an out-of-range update changing another factor |
| `before/rtl02_08_systile.log` | 1,491 dispatches recorded before the crossbar took them; a host completion accepted and discarded |
| `before/rtl04_systile.log` | a torn RESULT read, `220000008800` |
| `before/rtl08_xbar_bound.log` | at NENG = 8 every engine flagged bad |
| `before/host01_*.log` | out-of-range descriptor fields packed silently; a memory command on an image without memory hung waiting for bytes |

Each "before" log comes from the same benches run against the RTL with that
one fix removed, in a scratch copy of the repository.

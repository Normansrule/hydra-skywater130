# Lint and harden-plateau release (v52.2), 2026-10-13

| file | what it is |
|---|---|
| `lint_before_v52_project.log` | Verilator 5.020 `--lint-only -Wall` (DECLFILENAME, EOFNEWLINE off, as LibreLane) on the v52 `tt/tile/src/project.v`: 93 warnings |
| `lint_after.log` | `tools/lint/lint.sh` on this release: the tile netlist and the OpenFrame chip, 0 warnings |
| `verify.log` | `make -k verify` after every change in this release, including `make lint` |
| `mutate_formal_dma_mom.log` | `make mutate`: formal-target, memory-path (26/26) and dispatcher (8/8) mutations. The run was stopped by a time limit during its last step, the tile suite, which ran on its own: |
| `tile_mutate_sim.log` | `tt/tile/test/mutate_sim.py`: 17/17 killed |
| `ci_selftest.log` | `scripts/ci_selftest.sh`: 13 breaks caught, 9 clean runs pass |

Not in here: any harden of v3.2. The 4×4 return and the slew/capacitance
margins are untested until one runs. LibreLane's own Verilator may be newer
than 5.020 and could report warnings this one does not.

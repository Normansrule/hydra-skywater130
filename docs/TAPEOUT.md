# Hardening and submitting the tile

Not done in session 179: v2 has never been through LibreLane, so its area and
Fmax on sky130 are unknown. Everything below is the procedure, not a result.

## 1. Harden at the current size

The tile is `tiles: "3x4"` at `CLOCK_PERIOD` 55 (18 MHz signoff). Push the
session-179 commit to the tile repository and let the TinyTapeout GitHub
action build the GDS, or harden locally following
<https://tinytapeout.com/guides/local-hardening/>.

Read, in this order:

1. **Did it fit?** Utilisation in the LibreLane report. v2 adds an SPI target,
   a 14-register block, a captured 128-bit descriptor and the read multiplexer
   on top of v1.
2. **Did timing close at 55 ns?** If not, the critical path is almost certainly
   still inside the MOM (on ECP5 it runs through the cost register into the
   scoreboard's queue depth), not in the new register block.
3. **DRC, LVS, antenna.** Same as v1.

## 2. If it does not fit

Raise `tiles` in `info.yaml` and let the flow regenerate the configuration.
Do **not** hand-edit the floorplan: the v1 header records what that cost on the
ASICirific submission (three weeks, and DRC/LVS/timing all passing against the
wrong die because `FP_SIZING` was missing).

Sizes are per shuttle. The template lists 1x1 through 8x2 and describes a tile
as roughly 167 x 108 um; ChipFoundry sky130 shuttles have also allowed
4-tile-high designs, which is what `3x4` already uses. Confirm what your
shuttle accepts before assuming 4x4 is available.

## 3. If area is tight, drop this first

In `hydra_tt_regs.sv`, the `LASTWD` register (the descriptor as dispatched,
128 flops) and its read path are the largest new item. Removing it costs the
`test_reg_crossover_and_readback` assertion on `LASTWD` and nothing else: the
host already knows what descriptor it sent.

## 4. Gate-level

`GATES=yes make` in `tt/tile/test` runs the same 17 tests against the hardened
netlist. Both personalities must pass there, not just in RTL.

## 5. Still open from the session-144 handoff

The TinyTapeout slow-corner timing has never been read. Push the tile, wait for
the `gds` job, pull `GDS_logs.zip`, and grep for
`timing__setup__ws__corner:nom_ss_100C_1v60`. Previous attempts returned
utilisation, DRC and LVS but no timing lines, so check the `gds` job log
directly or look for a second artifact.

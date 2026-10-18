# HYDRA-TT-A: research scheduler tile

**PRELIMINARY EVALUATION SPECIFICATION, revision 0.2 (2026-10-13).** This is
not a product datasheet. Values marked TBD have not been measured. Nothing
here comes from silicon, because no tile has been fabricated or tested.

| | |
|---|---|
| Design | `tt_um_hydra_mom`, [tinytapeout-hydra](https://github.com/Normansrule/tinytapeout-hydra) |
| Source revision | v3.2: tile commit `452a59a4` plus the R7, MODEL-01/02 and RTL-04 fixes, the lint cleanup and the 4×4 return in this release |
| Scope | **scheduler only.** It has no compute engines, no encryption and no security mode. It decides which of five engine slots *would* be cheapest and reports that decision |
| Process | SkyWater sky130, Tiny Tapeout 4×4 tiles (v3.2; 3×4 did not route; not yet hardened) |
| ID register | `HYM3` |
| Descriptor ABI | version 1, 128 bits (`mom/rtl/mom_pkg.sv`) |
| Tags in flight | 4 |

## Pins

| pin | function |
|---|---|
| `ui[0]` | SPI SCK, mode 0, at most clk/8 |
| `ui[1]` | SPI COPI |
| `ui[2]` | SPI CSn, active low |
| `ui[7:3]` | unused |
| `uo[0]` | SPI CIPO |
| `uo[1]` | IRQ: any sticky STATUS flag, **including dispatched**. CLEAR_STICKY clears it |
| `uo[4:2]` | engine of the last dispatch |
| `uo[5]` | dispatched (sticky) |
| `uo[6]` | at least one tag outstanding |
| `uo[7]` | ready for a descriptor |
| `uio[1:0]` | tag of the last dispatch; `uio[3:2]` always 0 |
| `uio[7:4]` | 1 + ⌊log₂(runner-up margin)⌋, or 0 if there is none |

The register map and a worked example are in the tile's `docs/info.md`.

## Behaviour guaranteed by test

| property | test |
|---|---|
| a torn or wrong-length frame changes nothing and sets FRAME_ERR | `test_reg_torn_frames_change_nothing` |
| a descriptor write while a GO is pending is refused (FRAME_ERR); the pending descriptor is unchanged | `test_reg_wd_write_while_pending_is_refused` (v3.1) |
| a fence on a tag ≥ 4 reads as not busy | `test_reg_fence_on_a_tag_that_does_not_exist` (v3.1) |
| HOLD applies backpressure without losing a descriptor | `test_reg_hold_backpressure` |
| retuning a parameter row moves the decision | `test_reg_param_retune_moves_the_decision` |

21 tests on RTL, including a frame cut at every byte boundary (`test_reg_abort_at_every_byte_boundary`). A gate-level run of v3.1 waits for its harden.

## Timing and electrical

| parameter | value | source |
|---|---|---|
| Clock, signed off | 66 ns (15.15 MHz), every corner, on the **v2** harden | LibreLane, 2026-10-05 |
| Clock, v3.2 | 66 ns (15.15 MHz), every corner, worst setup slack +5.62 ns, hold +0.106 ns | LibreLane, 2026-10-14 (4×4) |
| Clock, v3.4 | 66 ns (15.15 MHz), every corner, worst setup slack +11.14 ns, hold +0.107 ns | LibreLane, 2026-10-17 (4×4) |
| Supply current, I/O levels, absolute maxima | TBD; Tiny Tapeout's shuttle documentation governs | not measured |
| SPI SCK | at most clk/8 | design rule, simulated |

## Known errata

| id | description | status |
|---|---|---|
| E1 | Before v3.1, a WD write during a pending GO could change the pending descriptor | fixed in v3.1 (R7) |
| E2 | Before v3.1, a fence index ≥ 4 read past the busy vector | fixed in v3.1 (R7) |
| E3 | The cost model's nominal engine sizes differ from any built engine | by design; calibration and PARAM correct it |
| E4 | Before v3.1, the calibrated cost could be up to 50 % low (normalisation chose its shift from the highest nonzero byte) | fixed in v3.1: at most 1/256 low (MODEL-01, `make cost-cal`) |
| E5 | Before v3.1, the calibrator's comparison could wrap and move a factor the wrong way; an out-of-range update index could overwrite another factor | fixed in v3.1 (MODEL-02) |
| E6 | Before v3.1, a multi-byte read could mix values from before and after a dispatch | fixed in v3.1: registers up to 6 bytes are read as one snapshot (RTL-04) |
| E7 | An engine the scheduler stops choosing is never re-measured, so its factor does not recover from a transient slowdown | known limitation, asserted by `make systile`; not changed |
| E8 | v3.1 at 3×4 tiles did not route (detailed routing 10,085 → 4,190 violations, not converging) | fixed in v3.2: 4×4, hardened clean 2026-10-14, 21/21 tests on its netlist |
| E9 | Every harden so far has about 5,000 max-slew warnings at the slow corner | v3.2's 50% margins: 3,665 (11 capacitance). Traced to fanout buffers built from the `clkdlybuf4s25_1` delay cell; v3.3 excludes that cell (its 50% run hung); v3.4 keeps the exclusion at 20% margins: hardened clean 2026-10-17 with 4,197 slew warnings at the slow corner (worst -1.551 ns) and 30 capacitance, now on `buf_1` fanout buffers; v3.5 excluding `buf_1` too failed setup (-2.403 ns, delay gates used instead). Open |

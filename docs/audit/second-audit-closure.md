# Engineering audits of 2026-10-11: closure

Two audits, both against parent `d174416` and tile `452a59a4`:

1. *HYDRA Second Engineering Audit: FHE / Sequestered Execution /
   CPU-GPU-TPU Integration / FPGA Readiness* (items R1–R8, work order 1–11).
2. *HYDRA SkyWater130: Full Engineering and Documentation Audit* (items
   RTL-01–08, MODEL-01–03, BUILD-01–03, FPGA-01, HOST-01 and the
   documentation sections). It is closed in the [last section](#skywater-130-audit).

## Revisions

| repository | audit baseline | HEAD when work started | relation |
|---|---|---|---|
| hydra-skywater130 | `d174416` | `d174416` | same; nothing newer to preserve |
| tinytapeout-hydra | `452a59a4` | `452a59a4` | same |
| sixfold-cpu | inspected by the audit | `a642bd6` | read only, not changed |
| pixelstorm-gpu | inspected by the audit | `4801c8c` | read only, not changed |

All changes are on top of the baselines. Every changed file is listed in the
release's `git diff --stat`.

## Classifications

**FIXED AND VERIFIED**: a test failed before the fix and passes after it, and
the full regression passes. **TESTED AND NOT DEFECTIVE**: a directed test or
mutation shows the suspected fault cannot happen. **DEFERRED**: not done, with
the technical reason. **BLOCKED**: needs evidence that cannot be produced
here (a board, a tool licence, a run log).

"Fix removed → caught" means the mutation suite puts the old behaviour back
and the bench fails. That is the reproducible before and after for the fix.

## Defects R1–R8

| item | classification | what changed | evidence |
|---|---|---|---|
| **R1** memory TPU bypassed by the completion selector | FIXED AND VERIFIED | One exclusive personality, `TPU_ENGINE` (0 model, 1 pattern, 2 memory) and `SIMD_ENGINE`. Ready, done and tag all come from the selected personality. An unknown value stops elaboration | `make systile-mem`: two back-to-back GEMMs (k = 300 then 40). Every cycle it checks that a completion is the array's own, with the same tag, and that a dispatch finds the array ready. Results must be in memory when the busy bit falls. Before the fix: early completion, a job admitted while busy, results missing |
| **R2** NTT packing not width-generic | FIXED AND VERIFIED | Memory format v1: one residue per 32-bit word, 8 result words per group, group-unit bases, sizes derived from N and DEPTH. Residues ≥ q are refused at the load port | `make ntt-moduli` runs the memory path at q = 3329, 8380417 and 12289: random values, edges 0 and q−1, last legal groups, the maximum job, refusals and reset mid-job. Fix removed → caught (`make dma-mutate`: y0/y1 order, base unit, residue check) |
| **R3** address width and completion semantics | FIXED AND VERIFIED | The result pointer is sized for the real bank (`CAW`). Jobs past a bank's end are refused before they start (status 4). A commit barrier holds done until the streamer and serialiser are idle. A refused descriptor no longer starts the streamer | `make dma dma-simd dma-ntt`: results read on the cycle done is seen, top of bank, one past the end, overlap, invalid descriptors, engine free afterwards. Fix removed → caught (`make dma-mutate`, 26 of 26) |
| **R4** ULX3S baud | FIXED AND VERIFIED | The divisor is generated from the plan's PLL output and must be within 2 %. ULX3S: 109 (−0.45 %). Comments corrected | `make uart-baud`: an independently timed host at −2 %, 0 and +2 %, 256 bytes each way, for every generated image. Before: 12.5 MHz / 104 failed at +2 % |
| **R5** multi-modulus loop masks failures | FIXED AND VERIFIED | `scripts/ntt_moduli.sh` checks every stage and the case count, in a fresh directory per modulus. `scripts/runsim.sh` wraps every simulation. Simulation scratch moved from shared `/tmp` names into `build/sim` inside each checkout | `NTT_MODULI_INJECT=model\|sv2v\|iverilog\|sim\|count` each fail. `scripts/ci_selftest.sh` breaks 13 things and runs 9 clean targets; every break is caught (22 runs). It is a CI step |
| **R6** build provenance and timing gates | FIXED AND VERIFIED (local); impossible-clock gate **BLOCKED** until CI runs | `.srchash` covers sources, constraints, the Makefile and tool versions. A `.manifest` sits beside each bitstream. nextpnr runs without `--timing-allow-fail`; Vivado fails on negative WNS or WHS. A missing artifact fails the upload | A pin-only change re-places the design (`srchash` changes). The CI step "An impossible clock must fail the build" needs nextpnr, which is not installed here |
| **R7** tile descriptor ownership, fence range, IRQ text | FIXED AND VERIFIED | A WD write while a GO is pending is refused (FRAME_ERR). A fence on a nonexistent tag reads not busy. IRQ documented as any sticky flag, including dispatched | Two tile tests that failed before the fix and pass after. A new abort-at-every-byte-boundary test passes. Tile suite 21/21. `test/mutate_sim.py` puts each fix back → caught |
| **R8** host writes during a job | FIXED AND VERIFIED | Each memory-fed engine owns its banks from acceptance until it reports completion. Host writes in that window are refused, reported on `ld_refused`, and returned to the PC in the bridge's write acknowledgement (`B2 01`). The host driver treats a refusal as a failed write | New R8 sections in all three memory benches write junk on every cycle of a job. Before: TPU 16/16 results corrupted and 144 operand words overwritten; vector unit 179/256 and 102; NTT 375/512 and 64, with 0 of 645 writes reported. After: exact results, operands intact, every write reported. Fix removed → caught (4 mutations). **Not a security boundary:** reads and the idle period are not enforced |
| memory-energy overflow (withdrawn by the audit) | DEFERRED | none | The audit does not reassert it. No fix is made without a failing case |

## Defects found during this work, not in the audit

| defect | classification | evidence |
|---|---|---|
| sv2v turns `$fatal` into `$finish(1)` and Icarus exits 0, so **every** sv2v testbench could fail silently, not only the modulus loop | FIXED AND VERIFIED | `runsim.sh` on every recipe; caught by `ci_selftest.sh` |
| several system benches had no watchdog; a hang ran forever | FIXED AND VERIFIED | watchdogs and a runsim wall-clock limit; "dispatcher never retires" is caught |
| a descriptor the core refuses started the TPU and vector-unit streamers, wedging the engine | FIXED AND VERIFIED | refusal tests in `dma` and `dma-simd`; fix removed → caught |
| Arty (25 MHz / 104) and Tang Nano (27 MHz / 104) serial ran at about twice the intended baud | FIXED AND VERIFIED | `make uart-baud`: the old values fail at every offset |
| the engine descriptions in `mom_pkg.sv`, `ISA.md` and the README said 16×16 and 8 butterflies; the built engines are 4×4 and 4 | FIXED | documentation only; `ISA.md` regenerated |

## Work order items 4–11 and the six-cell requirement

| item | classification | reason |
|---|---|---|
| 4. ULX3S on a physical board | **BLOCKED BY MISSING EVIDENCE** | Needs the board, an oscilloscope and a person. The procedure and record template are in `docs/bringup/ulx3s-85f.md` |
| 5. CPU, GPU and TPU integration | **DEFERRED** | The audit's order puts item 4 first. Interface facts and the integration plan are in `docs/architecture/heterogeneous-system.md`. The CPU top has no external memory port (its programs load through a simulation-only `$readmemh`), so it needs a load port first. The GPU's interface already fits |
| 6. FHE profile | **DEFERRED** (specification written) | BFV via a pinned OpenFHE is proposed in `docs/security/fhe-profile.md`. No parameters are chosen without the library generating them. The present butterflies (≤ 23-bit moduli, no transform control, no RNS) cannot carry it |
| 7. SE | **DEFERRED** (specification written) | `docs/security/se-contract.md` lists ten required parts. One exists in part (R8 write ownership) |
| 8. security mode and engine policy | **FIXED AND VERIFIED (host side)**; hardware **DEFERRED** | `tools/hydra_host.py check_job` treats them as two separate settings, admits only (PUBLIC_DEBUG, AUTO), and refuses everything else before the board sees it (`make tools`, 4 tests). The v1 descriptor has no field for them; ABI v2 is specified, not built |
| 9. mode transition | **DEFERRED** (specification written) | `docs/security/mode-transition.md`. There is nothing to transition between until a second mode exists |
| 10. larger-board synthesis | **BLOCKED BY MISSING EVIDENCE** | Needs Vivado with the device licence and the integrated design. No fit is claimed |
| 11. README and datasheets | FIXED | README headline per the audit; capability matrix; datasheets labelled Preliminary Evaluation Specification with TBD for every unmeasured value. The animated and interactive figures were not redrawn |
| six FHE/SE × CPU/GPU/TPU cells | **UNSUPPORTED** | each is refused by `check_job` and tested as such; none has a positive test or a board result |
| tile GDS workflow, 2026-10-09 (audit S34) | **BLOCKED BY MISSING EVIDENCE** | This session cannot read the tile's GitHub Actions logs. It does not matter for the current source: R7 changes `project.v`, so v3.1 needs a new harden in any case |

## SkyWater 130 audit

Items that duplicate the second audit point to the row above.

| item | classification | what changed | evidence |
|---|---|---|---|
| RTL-01 memory-fed TPU completion | FIXED AND VERIFIED | = R1 | `make systile-mem` |
| **RTL-02** dispatch status from local acceptance, not the crossbar | FIXED AND VERIFIED | `hydra_tt_regs` records a dispatch on a new `disp_fire` input. Each wrapper drives it from the handshake `mom_top` really sees: the crossbar's in the system tile, valid-and-not-HOLD in the tile | `make systile` section 5 counts register-block dispatch events against crossbar transfers on every cycle, with a job waiting on a busy engine. Before: 1,596 recorded against 105 transfers (1,491 early). After: 105 and 105. Fix removed → caught (`make mom-mutate`) |
| RTL-03 pending descriptor ownership | FIXED AND VERIFIED | = R7 | tile tests; also `test_reg_abort_at_every_byte_boundary` (every byte boundary of WD and PARAM) |
| **RTL-04** multi-byte read coherency | FIXED AND VERIFIED | Registers up to 6 bytes: byte 0 goes out live and the rest is captured in the same cycle (40 bits). The 16-byte WD changes only by host writes; LASTWD (chip only) is documented as "read with HOLD set" | `make systile` section 6 records every value RESULT holds during each read while jobs dispatch on their own. Before: a read of `220000008800`, a value RESULT never held. After: 0 torn. Fix removed → caught |
| RTL-05, RTL-06 NTT transport, addresses, completion | FIXED AND VERIFIED | = R2, R3 | `make ntt-moduli dma dma-simd dma-ntt` |
| RTL-07 fence index | FIXED AND VERIFIED | = R7 | tile tests |
| **RTL-08** host completion in the system tile | FIXED AND VERIFIED | A `HOST_COMP` parameter on the chip's register block; the system tile sets it to 0, so a COMP write is a FRAME_ERR rather than accepted and discarded | `make systile` section 7. Before: status `9000`. After: `9100` (FRAME_ERR). Fix removed → caught |
| **RTL-08** crossbar engine bound at NENG = 2^ENGW | FIXED AND VERIFIED | The bound is compared one bit wider. Elaboration stops if NENG > 2^ENGW | `make xbar-bound` instantiates NENG = 1, 5, 7 and 8 and dispatches to engines 0–7. Before: at NENG = 8 every engine was flagged bad and none forwarded. After: all correct. The existing crossbar proof and the 20,000-vector model comparison still pass |
| **MODEL-01** cost normalisation precision | FIXED AND VERIFIED | The shift is the smallest that makes the prediction fit 16 bits (it used to be chosen from the highest nonzero byte). Error ≤ 1/256, with the same three multiplexers | `make cost-cal` compares with the EXACT product at every exponent boundary (2ⁿ−1, 2ⁿ, 2ⁿ+1), at random values and at every k from 4 to 255: 41,076 products. Before: 511 → 256 and 131071 → 65536 (≈ 50 % low). After: all within 1/256. Fix removed → caught |
| **MODEL-02** calibration wrap and update index | FIXED AND VERIFIED | Compared at 34 bits. An update index outside the table updates nothing and is not counted | `make cost-cal`. Before: k = 68 with a prediction near 2³² and a measurement of 1024 moved k UP to 72; an update to engine 7 changed k[1][6]. After: k moves down to 64, and nothing changes. Fix removed → caught (2 mutations) |
| MODEL-03 adaptation quality, recovery, starvation | DEFERRED WITH TECHNICAL JUSTIFICATION | none | A policy choice (decay, exploration or host recalibration), not a defect. It needs a workload benchmark to choose between them. The current behaviour (no recovery) is asserted by `make systile` so that it cannot change silently, and it is listed as datasheet erratum E7 |
| BUILD-01 multi-modulus loop | FIXED AND VERIFIED | = R5 | `scripts/ci_selftest.sh` |
| **BUILD-02** dependencies and provenance | FIXED AND VERIFIED | In addition to R6: the plan file is a hashed input and is listed in the manifest, and every nextpnr call names `--seed 1`, which the manifest records | regenerated `fpga/build/*/Makefile` |
| **BUILD-03** reproducible, inspectable evidence | FIXED AND VERIFIED (partly) | `site-check` compares in memory and writes nothing (`gen_site.py --check`). `verify.log` is uploaded on every run, pass or fail. sv2v and the Python packages are pinned in `bootstrap-ubuntu.sh`. The new mutation suites are in `make mutate` | A container digest or full lockfile is **DEFERRED**: apt packages (yosys, iverilog) still float with Ubuntu 24.04 |
| FPGA-01 ULX3S UART | FIXED AND VERIFIED | = R4 | `make uart-baud` |
| **HOST-01** descriptor range checks; memory commands on images without memory | FIXED AND VERIFIED | `descriptor()` raises on any out-of-range, negative or non-integer field instead of masking it. The bridge answers `EE` to memory commands unless `HAS_MEM` is set (only `ecp5-evn-mem` sets it) | `tools/test_hydra_host.py`: the new test fails on the v51 driver and passes now. `make harness`: before, a memory write on the scheduler image waited for bytes and timed out; now it is `EE 4D`. Fix removed → caught |
| README structure | FIXED | A new 150-line README with a live-text H1, a status callout, a "what works now" table, an as-built figure with a text description, a first simulation, target selection, an evidence table and a documentation map. The old README is kept whole as `docs/ENGINEERING_NOTES.md` | links checked: no dead internal links |
| Hero figure | FIXED | Static. Labelled as an area chart, not a floorplan; pad ring removed; tile facts labelled as the tile's | `make readme-check` |
| Architecture views | FIXED AND VERIFIED | Three views: as built (one named plan, each module checked as **instantiated** in that plan's sources), IP library (no edges) and roadmap (planned). The tile repository now shows its own scheduler-only view | `make site-check` |
| Site numbers | FIXED | The hard-coded cards (44, 8, 1,608) are gone. Proof tasks are counted from what `make verify` runs (20 proofs, 5 covers), not from .sby files. Every verification row names its make target, and the generator refuses a row whose target does not exist | `make site-check` |
| Site accessibility | FIXED AND VERIFIED (automated) | Skip link, `main` landmark, section navigation, focus-visible outlines, `scope` on table headers, text versions of both diagrams, print styles, phone padding | Rendered with Chromium at 320, 375, 768 and 1440 px, light and dark: no page-wide overflow at any width; the first Tab lands on the skip link; the text versions are present with JavaScript off. Screen-reader and zoom testing by a person: **not done** |
| Animations | FIXED (lead figures), DEFERRED (controls) | The README hero and the tile hero are static. The dispatch animation is linked rather than embedded in the tile README | Play/pause/step controls on the site, and animation driven by recorded traces, are **DEFERRED**: the site's figures do not animate today |
| GitHub Pages deployment | BLOCKED BY MISSING EVIDENCE | none | Needs the repository owner to enable Pages. The README links the page as a local file and says it is not deployed |
| Getting-started tutorial | FIXED | `docs/GETTING_STARTED.md`; `FIRST_TRY.md` retitled as release and tapeout preparation | — |
| ASIC power grid, full-chip sign-off | BLOCKED BY MISSING EVIDENCE | none | No full-chip layout exists. The tile's v3.1 needs a new harden, and its reports must be inspected then |

## Tile harden plateau and lint (2026-10-13)

| item | classification | what changed | evidence |
|---|---|---|---|
| v3.1 harden at 3×4: detailed routing not converging (10,085 → 5,223 → 4,558 → 4,338 → 4,190) | FIXED AND VERIFIED | `tiles: "4x4"` in `info.yaml`; `PL_TARGET_DENSITY_PCT` 70 → 60. At 3×4 the cells fill about 70% of a core routed on met1–met4 only, and `GRT_ALLOW_CONGESTION` passes global-routing overflow on to detailed routing | Counts read from the run's log (`grep "Number of violations"`, 2026-10-13); `tools/drt_progress.py` projects about 55 left at iteration 63 even at the most favourable recent rate, so the run was stopped. A v3 run at 4×4 (2026-10-10) signed off clean at 52% with 18/18 gate-level tests. **v3.2 at 4×4, 2026-10-14:** detailed routing 971 → 245 → 196 → 10 → 0; DRC, LVS, antenna 0; setup +5.62 ns and hold +0.106 ns worst corner; 53.5%; `make tile-gl` 21/21 |
| about 5,000 slow-corner max-slew warnings on every harden (4,764; 4,996; 5,039) | DEFERRED WITH TECHNICAL JUSTIFICATION (not a sign-off item; v3.4 signs off clean with them; two targeted fixes measured, one rejected) | v3.2: `DESIGN_REPAIR_MAX_SLEW_PCT` and `DESIGN_REPAIR_MAX_CAP_PCT` 20 → 50. v3.3: `EXTRA_EXCLUDED_CELLS` = `sky130_fd_sc_hd__clkdlybuf4s*` | v3.2 harden: 3,665 slew (3,137 at nom_ss, 295 at nom_tt, 66 at nom_ff) and 11 capacitance. `tools/slew_report.py`: the worst nets at both ss and tt are all driven by `fanoutNNN` buffers of type `clkdlybuf4s25_1`, a delay cell, with 10–15 loads each (1,093 instances); every capacitance violator is one of them. Margins cannot fix a cell that cannot drive. v3.3 (exclusion, 50% margins): the exclusion took effect (input buffers `buf_1`), then the post-placement repair step hung for over a day at net 7,000 of 11,823 and was stopped. v3.4: margins back to 20%, exclusion kept; `tools/harden_ladder.py` (`make harden`) stops a stalled rung after 60 min and falls back to the pre-v3.2 settings. **v3.4 result, 2026-10-17:** first rung signed off in 11 minutes; setup +11.14 ns, hold +0.107 ns; 21/21 gate level; worst slew nets now `buf_1` fanout buffers at -0.415 ns (v3.2: -1.255 ns). Total slew count, from that run's `checks.out` and `final/metrics.json`: 4,197 at max_ss_100C_1v60 (worst -1.551 ns), 635 at nom_tt_025C_1v80 (worst -0.633 ns), 30 capacitance; all nine corners in `docs/timing.json`. 88% of the slow-corner pins are on nets driven by the 1,082 `buf_1` fanout buffers; slew is 11 after clock-tree synthesis and 57 after global routing (typical corner, estimated wires) and appears only on the extracted wires. A second harden of the same settings on 2026-10-17 reproduced every number. **v3.5** (also exclude `buf_1` and `clkbuf_1`): the resizer used `dlygate4sd3_1` for every fanout buffer; slew 3,298, capacitance 8, but setup -2.403 ns at max_ss_100C_1v60, rejected by the ladder. Next candidate (`realbuf2` in `tools/harden_ladder.py`): exclude the delay gates as well, so repair can pick only `_2` or stronger real buffers. The post-GRT margins are not set: they act only with `RUN_POST_GRT_DESIGN_REPAIR`, which LibreLane marks experimental |
| Verilator `-Wall` warnings in the submitted `project.v` (93) | FIXED AND VERIFIED | Widths made explicit (`'0` fills, 32-bit index comparisons instead of casts), intentionally unused bits consumed by name, dead wires removed (`t_setup`, `step`, a debug block, `KCAL_W`), and `regen.sh` drops the package constants sv2v copies in and leaves unreferenced | `make lint`: 0 warnings with LibreLane's settings. Generic synthesis 18,122 → 17,969 cells. Behaviour, re-run after the change: `make verify` passes (21/21 tile tests, every simulation and proof); 17/17 tile mutations, 26/26 memory-path mutations, 8/8 dispatcher mutations and every formal-target mutation killed; `ci_selftest` 22/22. Equivalence with the v52 netlist is not formally proven |
| Verilator `-Wall` on the OpenFrame chip | FIXED AND VERIFIED, one waiver | The same fixes plus the pad multiplexer's selection widths, `r_lastwd` and the pin wrapper's shift register. One waiver (`tools/lint/waivers.vlt`): the personality strap is sampled while the raw reset is low, which is intended | `make lint` |
| Verilator `-Wall` on the FPGA images | DEFERRED WITH TECHNICAL JUSTIFICATION | none | Built by Yosys and nextpnr, not linted by Verilator in any flow; several hundred width warnings remain in the engine and board RTL. Not part of either SkyWater design |

## How to reproduce

```bash
cd ~/src/hydra-skywater130 && make -k verify && make mutate && ./scripts/ci_selftest.sh
```

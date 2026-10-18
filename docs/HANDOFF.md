# HYDRA-130: Adaptive Heterogeneous Scheduler — Tiny Tapeout, SkyWater 130 and FPGA

**Agent handoff, 2026-10-17 (package v52.7).** Read this first, then
`README.md`, `docs/verification/capability-matrix.md` and
`docs/audit/second-audit-closure.md`. The capability matrix is the authority
on what runs; this file is the authority on what to do next and how.

## 1. What the project is

HYDRA-130 is a research chip built around the **Mathematical Operation MUX
(MOM)**: a hardware scheduler that takes a 128-bit work descriptor (one
descriptor is one "instruction"), predicts with a roofline cost model how long
each engine would take, dispatches to the cheapest **eligible** engine, measures
the real completion time and recalibrates itself. The point of the project is
**switching work between CPU, GPU and TPU** (plus vector, number-theoretic
transform (NTT) and crypto slots) by cost, under a security policy, from one
job interface.

Owner: Aleksander J. Norman. Repositories:

| repository | role |
|---|---|
| `Normansrule/hydra-skywater130` | parent: all RTL, models, testbenches, proofs, FPGA builds, SkyWater OpenFrame chip, docs, site |
| `Normansrule/tinytapeout-hydra` | Tiny Tapeout tile, a **submodule** at `tt/tile`; scheduler only |
| `Normansrule/sixfold-cpu` @ `a642bd6` | 6-stage RV64IM+Zba/Zbb/Zbs CPU; **not integrated** |
| `Normansrule/pixelstorm-gpu` @ `4801c8c` | SIMT GPU, 2 SMs × 4 warps × 8 lanes, 40-instruction CUDA-style ISA; **not integrated** |

## 2. The three deliverables (keep them apart)

| target | what it must be | state today |
|---|---|---|
| **Tiny Tapeout tile** (`tt_um_hydra_mom`) | research tile, **scheduler only**, low cost and power: cost model, calibration, SPI register map, 4 tags. Never add engines to it | **v3.4 hardened clean at 4×4 on 2026-10-17**: DRC, LVS, antenna 0; setup +11.14 ns, hold +0.107 ns at 66 ns (15.15 MHz); 51.7%; 21/21 tests on the hardened netlist. v3.1 at 3×4 did not route |
| **SkyWater 130 OpenFrame chip** (`sky130/rtl/hydra_openframe_top.sv`) | the full chip: CPU, GPU, TPU and the MUX switching between them, pads, bring-up, security | RTL with the scheduler, pad multiplexer and SPI only; simulated through its pads (`make sky130`); Verilator-clean; **never hardened**; no engines yet |
| **FPGA** (`plans/*.yaml`, `fpga/build/*`) | adaptable to current dev boards, for testing before silicon; serial UART and JTAG paths | images for ULX3S-85F, ECP5 evaluation (`-sys`, `-tpu`, `-two`, `-mem`), Arty A7-35, Tang Nano 20K, Basys 3 (self-test only, no HYDRA logic). **No image has run on a physical board.** ULX3S placed and routed in CI before the baud fix |

The tile and the chip share nine dispatcher modules byte for byte
(`make tile-shared`). A change to the cost model therefore changes both;
chip-only changes (a sixth engine slot, ABI v2) must not touch those modules
unless the tile is re-verified and re-hardened.

## 3. CPU / GPU / TPU switching — the central goal

Today (version 1 descriptor ABI, `mom/rtl/mom_pkg.sv`, `docs/ISA.md`):

- Five engine slots: **0 CPU, 1 SIMD (vector), 2 TPU, 3 NTT, 4 CRYPTO.**
- One shared cost engine evaluates the eligible engines in turn (two cycles
  each, about 13 cycles per decision). Engines that cannot do the operation
  class or data type are excluded **before** cost is compared.
- Calibration moves a per-engine, per-operation factor toward the measured
  time. Known limit (erratum E7): an engine that stops being chosen is never
  re-measured, so it does not recover from a transient slowdown. Asserted by
  `make systile` on purpose; changing it is policy work (MODEL-03).
- Real engines in RTL: the 4×4 INT8 systolic TPU (also fed from scratchpad
  banks), the 4-lane 32-bit vector unit (**not a GPU**), NTT butterflies at
  q = 3329, 8380417, 12289 (**not FHE**). CPU and CRYPTO slots are latency
  models.

Next (specified in `docs/architecture/heterogeneous-system.md`, not built):

- **ABI version 2**: header word with `abi_version`, `security_mode`
  (PUBLIC_DEBUG / FHE / SE), `engine_policy` (AUTO or force CPU/GPU/TPU/SIMD/NTT),
  `context_id`, `context_epoch`, `key_handle`, `profile_id`, then the v1 body.
  A v1 consumer must refuse v2.
- **Eligibility before cost**: present, healthy, op and dtype supported,
  security mode supported, context owned, and policy match. No eligible
  engine → defined error, never a silent fallback.
- **A sixth slot for the GPU** (`ENG_N` = 6, one more cost-ROM row) — chip
  only; the tile stays at five.
- **Integration order (Gate C)**: (1) run the ULX3S scheduler image on a
  board (`docs/bringup/ulx3s-85f.md`); (2) GPU first — Pixelstorm already has
  instruction/constant write ports, `launch`, `done` and a memory port; prove
  a real kernel over a HYDRA bank against Pixelstorm's own model, completion
  only after the last write, refusal of a malformed launch; (3) CPU —
  Sixfold needs a host program/data port and a done/halt handshake; prove a
  real program against its 108-run regression; (4) synthesise CPU + GPU +
  TPU + scheduler + bridge for a board.
- The CPU keeps its own instruction set (RV64); HYDRA submits a program
  address and arguments. Security instructions (Zknh + custom Xhydrasec,
  `isa/`, `docs/ISA_SECURITY.md`) belong both in HYDRA and in Sixfold.
- FHE and SE are **specifications only** (`docs/security/`); the host driver
  refuses them (`tools/hydra_host.py check_job`). Keep that true until each
  has positive and negative tests and a board result.

## 4. How work is verified (do not weaken any of it)

- Every simulation runs through `scripts/runsim.sh`: fails on a non-zero
  exit, any `FAIL` line, or a missing `PASS` line.
- Testbenches compare against **independent Python models** (e.g.
  `cost-cal`: 41,076 products within 1/256 of exact).
- Formal proofs with SymbiYosys (`make verify` runs 22 proof tasks and 5
  covers; counted from the Makefile, not from `.sby` files).
- **Mutation testing**: every named deliberate break must be caught —
  `tt/tile/test/mutate_sim.py` (17/17), `mem/formal/mutate_dma.py` (26/26),
  `tools/mutate_mom.py` (32/32: 8 dispatcher, 4 bridge host-path, 7 GPU, 3 six-slot, 5 ABI v2, 5 CPU), `common/formal/mutate_targets.py`, and
  `scripts/ci_selftest.sh` (22 runs). When code changes, update the anchors;
  never delete a mutation to get green.
- `make lint`: Verilator `-Wall` with LibreLane's settings, **0 warnings** on
  the tile netlist and the OpenFrame chip (one documented waiver). FPGA RTL
  is not linted (deferred).
- Tile: 21 cocotb tests on RTL (`make tile`) and on the hardened netlist
  (`make tile-gl`).
- `make verify` is the whole suite; `scripts/release.sh` runs it before it
  pushes both repositories in the right order.
- Every claim is classified: FIXED AND VERIFIED / TESTED AND NOT DEFECTIVE /
  DEFERRED WITH TECHNICAL JUSTIFICATION / BLOCKED BY MISSING EVIDENCE.
  **Never fabricate measurements, security proofs, FPGA validation,
  cryptographic correctness or ASIC sign-off.** A number in a document must
  come from a tool's output (metrics.json, a log the owner pasted).

## 5. Presentation style (README, site, figures)

- README: live-text H1, a development-status callout, a "what works now"
  table with evidence level and the command that checks it, the as-built
  figure for **one named build** (`plans/ecp5-evn-mem.yaml`) with a text
  description, a first simulation, target selection, an evidence table
  (what each kind of evidence does and does not establish), a docs map. The
  previous long README is kept whole as `docs/ENGINEERING_NOTES.md`.
- Figures are **generated**, never hand-drawn: `tools/gen_readme_art.py`,
  `tools/gen_readme_hero.py`, `tools/gen_site.py`. Dark theme SVG,
  orthogonal edges, no overlapping labels, text must fit at the rendered
  width (render with Playwright and look at it). The hero is an **area chart,
  not a floorplan**, and static (a README image cannot offer a pause control).
  The as-built view refuses to draw a block that is not instantiated in that
  plan's sources. IP library and roadmap are separate views.
- `make readme-check` and `make site-check` fail if figures or numbers drift
  from `docs/metrics.json` / `docs/timing.json`.
- The site `docs/site/index.html` is one self-contained file, **not
  deployed**: skip link, `main` landmark, section navigation, visible focus,
  `scope` on table headers, text versions of every diagram, print styles,
  no page overflow at 320, 375, 768 and 1440 px, light and dark.
- Datasheet `docs/datasheets/HYDRA-TT-A.md` is a preliminary evaluation
  specification with an errata table; TBD where not measured.
- Writing: plain, precise; spell out an acronym the first time with the
  acronym in parentheses.

## 6. Working with the owner

- Machine: Windows with **WSL2 Ubuntu** (host `Aleksander-Desk`). Browser
  downloads land in `/mnt/c/Users/aleks/Downloads/`, not `~/Downloads`.
  Parent at `~/src/hydra-skywater130`; hardening checkout at
  `~/src/tinytapeout-hydra`; LibreLane in `~/ttsetup/venv`; PDK at
  `PDK_ROOT=$HOME/.ciel` (never `/tmp`, which WSL empties); Docker Desktop.
- Deliver work as a **zip whose root is `hydra-skywater130/`**, overlaid with
  `cd ~/src && unzip -o <zip>`. If unsure what the owner has applied, ship a
  full snapshot.
- Commands: start with `cd`, chain with `&&`, one copyable block per step.
- Answers concise and direct. Commit or push only when asked; the owner runs
  `./scripts/release.sh`. Commits end with the session's attribution lines.
- Harden flow on the owner's machine: `make harden` (unattended; tries
  `buffers20`, then `proven20`; stops a stalled run after 60 min; stops on a
  network/Docker/Python failure; runs `tile-gl`, slew report and timing
  summary on success; copies one log to Downloads). Watch routing with
  `make drt-progress`.

## 7. What was done in the last sessions (v51 → v52.7)

- Two engineering audits closed (R1–R8; RTL-01..08, MODEL-01/02, HOST-01,
  BUILD-01..03; README, site and docs rewrite). Details and evidence:
  `docs/audit/second-audit-closure.md`.
- Tile `project.v` Verilator-clean (93 → 0 warnings); OpenFrame chip
  lint-clean; `make lint` added.
- Tile back to 4×4 (3×4 detailed routing went 10,085 → 4,190 and stalled).
- Slew root cause found: the resizer built fanout buffers from
  `clkdlybuf4s25_1`, a weak clock delay cell. Excluded via
  `EXTRA_EXCLUDED_CELLS` at the default 20% repair margins (50% margins made
  the repair step take hours, then hang).
- New tools: `tools/drt_progress.py`, `tools/harden_ladder.py`,
  `tools/lint/`, sync-tile fixed to back up compactly under `build/`.

## 8. What needs to be done, in order

1. **Record the v3.4 harden completely.** From
   `~/src/hydra-skywater130/build/harden-ladder/20261017-115622/` take
   `checks.out` (slew totals per corner) and the `HYDRA-TIMING` block of
   `timing_report.py --summary`; add the run to `docs/timing.json` (all nine
   corners, numbers only from that output), then `make readme-art site` and
   check the figures by rendering them. The README hero still quotes the v2
   harden until `timing.json` has v3.4.
2. If slew is still non-zero, read the slew report and fix it in a targeted
   way (buffer sizing, `MAX_FANOUT_CONSTRAINT`), one change per harden.
3. Owner pushes with `./scripts/release.sh`; the tile's GitHub GDS action
   produces the submission artefacts; check them against the local harden.
4. Run the ULX3S scheduler image on a real board and archive the log
   (`docs/bringup/ulx3s-85f.md`).
5. Basys 3: a HYDRA image (not just the self-test) with UART and the JTAG
   bridge (`dbg/`) as two independent host paths.
6. GPU integration (Pixelstorm), then CPU (Sixfold), behind ABI v2 with
   eligibility before cost — chip side only, with the evidence listed in §3.
7. Harden the SkyWater OpenFrame chip once engines are in it.
8. Deferred, with reasons in the closure table: calibration recovery policy
   (MODEL-03), FPGA lint, a container digest or lockfile, GitHub Pages
   (owner must enable), screen-reader testing by a person.

## 9. Session of 2026-10-17 (evening), after v52.7

- **v3.4 recorded**: all nine corners, slew and capacitance per corner in
  `docs/timing.json` (from `build/harden-ladder/20261017-115622/checks.out`);
  the hero, tile hero and timing figure now name the run from that file
  instead of a typed "v2". A second harden reproduced every number.
- **Slew, one change per harden**: v3.5 excluded `buf_1`/`clkbuf_1`; the
  resizer used `dlygate4sd3_1` delay gates instead and setup failed by
  2.403 ns, so the ladder rejected it and re-hardened v3.4. Next rung,
  `realbuf2`, also excludes the delay gates. Slew is not a sign-off item.
- **Basys 3 HYDRA image** (`plans/basys3.yaml`): the bridge takes a second
  host (`HAS_JTAG`), reached over the verified TAP and clock crossing in
  `dbg/` through `fpga/rtl/hydra_fpga_jtag_host.sv`. `make jtag-harness`
  checks each path alone, both together and that replies never cross; four
  breaks of that are in `tools/mutate_mom.py`. Not synthesized: no Vivado.
- **ULX3S** placed and routed locally after the baud fix (27.53 MHz against
  12.5 MHz). The board run in `docs/bringup/ulx3s-85f.md` still needs the
  board.
- `tools/drt_progress.py` reported a clean route as STUCK when the router
  started a second pass in the same log; it now judges the newest pass only
  (selftest case added).

## 10. Session of 2026-10-18

- Authorship: every commit in both repositories rewritten to Aleksander J.
  Norman only (owner's decision); git in WSL commits as him. No co-author
  trailers. Backups: `~/backups/history-rewrite-20261018-103221/`.
- Engine count: the nine shared modules take `NENG` (default 5). The chip
  uses 6, the GPU on slot 5 (`hydra_sys_tile`, `GPU_ENGINE = 1`). The
  selector's tree was fixed at five lanes; fixed and proved at 5 and 6
  (`make select-proof`).
- ABI version 2 on the chip: `sys/rtl/hydra_abi_v2.sv`, eligibility applied
  before cost through `mom_top`'s `eng_elig` (the tile ties it to all ones).
  `make abi-v2 systile-abi`.
- Tile: each netlist change proved equivalent before re-hardening (logs in
  `reports/fpga-harden-2026-10-17/`); v3.8 signed off clean. Slew moves with
  placement (775 on v3.6, 1,333 on v3.7, 1,164 on v3.8) for the same logic.
- Commands to test and publish: `docs/PUBLISH_AND_TEST.md`. Next: the
  Sixfold CPU behind ABI version 2, slew to zero, board runs.
- Sixfold CPU (submodule `ext/sixfold-cpu` @ a642bd6, unchanged) in
  `sys/rtl/hydra_engine_cpu.sv`: load port, done on HALTED, cycle limit,
  refusals. All 24 programs match the model's registers, TOHOST and cycle
  count (`make cpu`, slow; `make cpu-quick` in verify). The chip's slot 0
  (`CPU_ENGINE = 1`): `make systile-cpu`. Its 64 KiB same-cycle memory is a
  simulation arrangement: SRAM and Sixfold's caches come before synthesis.

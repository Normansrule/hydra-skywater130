# Capability matrix: what each part has been shown to do

Revision baseline: parent `d174416`, tile `452a59a4` (second audit,
2026-10-11), plus the changes listed in
[`docs/audit/second-audit-closure.md`](../audit/second-audit-closure.md).

Each cell names the **highest evidence level reached** and the command that
reproduces it. Levels, from weakest to strongest:

| level | meaning |
|---|---|
| **source** | RTL or code exists in the repository; nothing more is claimed |
| **simulated** | a self-checking simulation compares it with an independent model and fails the build on a mismatch |
| **synthesized** | mapped to cells or LUTs by a synthesis tool, with the report archived |
| **placed and routed** | a place-and-route run closed timing with the report archived |
| **board-tested** | run on a named physical board, with an archived log, image hash and board revision |
| **security-reviewed** | a written threat model, positive and negative tests, and an independent review |
| **UNSUPPORTED** | not implemented; a job that asks for it is refused (`tools/hydra_host.py check_job`) |

Nothing in this repository has reached **board-tested** or
**security-reviewed**. No cell below says otherwise.

## 1. Security mode × engine (the six required cells)

| mode | CPU | GPU | TPU |
|---|---|---|---|
| **FHE** | UNSUPPORTED (refused by the chip's ABI v2 front end too) | UNSUPPORTED | UNSUPPORTED |
| **SE** | UNSUPPORTED | UNSUPPORTED | UNSUPPORTED |
| PUBLIC_DEBUG | simulated as the chip's CPU slot (see 2) | simulated as the chip's sixth slot (see 2); not in an FPGA image or on a board | simulated (see 2) |

All six FHE and SE cells are refused by the host driver, and
`tools/test_hydra_host.py` checks that a refused job never reaches the
board. The full capability needs every one of the six cells to have positive
and negative tests and a board result. None has either today.

## 2. Engines

| engine | what is built | where | evidence | command |
|---|---|---|---|---|
| Scheduler | cost model, select, tags, calibration | `mom/rtl` | simulated in the tile, the system tile and against exact arithmetic (`cost-cal`); dispatch recorded on the real handshake; coherent reads | `make tile systile cost-cal` |
| TPU | 4×4 INT8 output-stationary systolic array | `engines/tpu` | simulated, formal port contract | `make tpu` |
| TPU fed from memory | the array, three scratchpad banks and the operand streamer | `sys/rtl/hydra_engine_tpu_dma.sv` | simulated: exact results, refusals, bank ownership (R8) | `make dma`, `make dma-mutate` |
| Vector unit (SIMD) | 4 lanes × 32-bit integer; **not a GPU** | `engines/simd` | simulated, formal | `make simd`, `make dma-simd` |
| NTT butterflies | 4 Barrett butterflies at q = 3329, 8380417 or 12289 (a build option) | `engines/ntt` | simulated at all three moduli, core and memory path | `make ntt-moduli` |
| NTT fed from memory | butterflies, memory format v1, commit barrier | `sys/rtl/hydra_engine_ntt_dma.sv` | simulated at all three moduli; **not in the system tile** | `make dma-ntt`, `make ntt-moduli` |
| ABI version 2 | header checks (version, reserved, mode, policy, context and epoch, key), eligibility mask applied before cost | `sys/rtl/hydra_abi_v2.sv`, `mom/rtl/mom_top.sv` (`eng_elig`) | simulated: 4,000 randomized cases against `sys/tb/abi_v2_model.py`, end to end on the six-slot chip (no context, AUTO, forced CPU, forced GPU on INT8, FHE, stale epoch, unhealthy GPU); proved (nothing forwarded without a passing header, mask non-empty and stable, FHE/SE never forwarded); 5 mutations caught | `make abi-v2 systile-abi` |
| CPU | Sixfold @ `a642bd6` (submodule `ext/sixfold-cpu`), RV64IM + Zba/Zbb/Zbs + Zknh, unchanged, in `sys/rtl/hydra_engine_cpu.sv`: host load port, start, done on HALTED, cycle limit, refusals; the chip's CPU slot (`CPU_ENGINE = 1`) | `sys/rtl/hydra_engine_cpu.sv` | simulated: all 24 Sixfold programs give the model's x1..x31, TOHOST and cycle count exactly (`make cpu`); refusals, limit and host-write ownership checked; scheduled through ABI v2 on the six-slot chip (`make systile-cpu`); 5 mutations caught. With Sixfold's own caches over block memory (`CACHED = 1`) all 24 programs match the cached model too (`make cpu-cached`). ECP5 synthesis of the cached build (`make cpu-synth`, yosys): 28,050 LUT4, 5,325 FF, 84 DP16KD, 735 TRELLIS_DPR16X4; not placed and routed, and CPU plus GPU (about 90.7k LUT4) exceeds the ULX3S-85F's 84k | `make cpu`, `make cpu-cached`, `make systile-cpu` |
| GPU | Pixelstorm @ `4801c8c` (submodule `ext/pixelstorm-gpu`), 2 SMs × 4 warps × 8 lanes, behind the engine contract with its global memory on one 4,096-word HYDRA bank; the chip's **sixth dispatcher slot** (`NENG = 6`, `hydra_sys_tile` with `GPU_ENGINE = 1`; the tile keeps 5) | `sys/rtl/hydra_engine_gpu.sv` | simulated: 14 kernels (13 of Pixelstorm's, plus one that uses an atomic's return value) leave all 4,096 words exactly as Pixelstorm's JavaScript model predicts; done only after the last write; refusal of grid 0, block 0, block > 32 and launch with no program; host writes refused during a job; past-the-end access reported; 7 mutations caught. Scheduled: a 32×32×64 INT32 GEMM goes to engine 5 through the SPI register map, the bank equals the model at retirement, an INT8 job stays off it (`make systile-gpu`, 3 slot mutations caught); selector proved at 5 and 6 slots (`make select-proof`). Synthesized for ECP5 (yosys 0.52): 62,625 LUT4, 4,021 flip-flops, 112 MULT18X18D, 6 DP16KD. Not placed and routed | `make gpu`, `make systile-gpu`, `tools/mutate_mom.py` |
| CRYPTO slot | latency model; SHA-256 exists separately in `sec/` | — | — | — |

The dispatcher's cost model uses its own nominal engine sizes (for example an
8×8 array and 8 butterflies in `mom/rtl/mom_param_rom.sv`). Those are
modelling parameters, not the size of the built engines above.

## 3. Builds

| build | contents | highest level | evidence |
|---|---|---|---|
| Tiny Tapeout tile | scheduler only: cost model, calibration, SPI register map, 4 tags | placed and routed (v2 at 4×4; v3 at 4×4 with 18/18 gate-level tests). **v3.4 at 4×4 hardened clean 2026-10-17** (DRC, LVS, antenna 0; every corner met, setup +11.142 ns, hold +0.107 ns; 21/21 gate level; 4,197 slew and 30 capacitance warnings, all nine corners in `docs/timing.json`), reproduced exactly by a second harden on 2026-10-17; v3.5 (no `buf_1`/`clkbuf_1`) failed setup by 2.403 ns and was rejected; **v3.6 (no weak or delay buffers) hardened clean**: setup +14.836 ns, hold +0.106 ns, 48.9%, slew 775 at the slow corners only, capacitance 0, 21/21 gate level; **v3.7** (same settings, netlist regenerated after the engine-count change and proved equivalent to v3.6's) signed off clean too: setup +9.387 ns, slew 1,333 at the slow corners, capacitance 1, 21/21 gate level; **v3.8** (eligibility input tied off for the tile, netlist proved equivalent to v3.7's) clean: setup +10.064 ns, slew 1,164, capacitance 0, 21/21 gate level; **v3.9** (slew repair margin 35%) clean, setup +10.314 ns, slew 759 at max_ss and 16 at each typical corner, 21/21 gate level, not adopted; **v3.10** (scheduler liveness fix: a job whose only capable engine was full when costed now dispatches when it drains) clean: setup +14.062 ns, hold +0.105 ns, slew 1,230 at max_ss and 21 / 11 / 11 at the typical corners, capacitance 0, 22/22 gate level; v3.1 at 3×4 did not route. `project.v` is Verilator `-Wall` clean (`make lint`) | `tt/tile` README, `docs/metrics.json` |
| SkyWater OpenFrame chip | scheduler pins and pad multiplexer; **no engines** | simulated | `make sky130` |
| `ecp5-evn` (and `ulx3s-85f`, `arty-a7-35`, `tangnano20k`) | scheduler and serial bridge | `ulx3s-85f`: placed and routed locally on 2026-10-17 after the baud fix (nextpnr-ecp5 0.9, 27.53 MHz against 12.5 MHz requested, image SHA-256 in `fpga/build/ulx3s-85f/hydra_ulx3s_tt.bit.manifest`), and in CI before it (run 38013429983). `arty-a7-35` and `tangnano20k`: generated only (no Vivado or Gowin flow installed) | `make -C fpga/build/ulx3s-85f`, `.github/workflows/verify.yml` |
| `ecp5-evn-sys` | scheduler, five latency models | simulated | `make systile` |
| `ecp5-evn-tpu`, `ecp5-evn-two` | scheduler, array and vector unit on generated patterns | simulated | `make systile-tpu`, `make systile-two` |
| `ecp5-evn-mem` | scheduler and the memory-fed array, host loads over serial | simulated | `make memboard`, `make systile-mem` |
| Basys 3 self-test | display and serial self-test; **no HYDRA logic** | simulated | `make basys3-selftest` |
| `basys3` (HYDRA image) | scheduler tile, serial bridge and a JTAG test port as a second host path (Pmod JA) | simulated: each path alone, both together, replies kept apart; 4 separation mutations caught. **Not synthesized** (no Vivado here) | `make jtag-harness`, `tools/mutate_mom.py` |

"Placed and routed in CI" is the workflow's own report. It is not a
physical-board result. [`docs/bringup/ulx3s-85f.md`](../bringup/ulx3s-85f.md)
is the procedure that would produce one.

## 4. Security primitives (not a security contract)

| block | what it does | evidence |
|---|---|---|
| key vault | slots the host can write and the engines can use, not read back; lock and wipe | simulated (`make keyvault`) |
| mailbox | the host-to-root-of-trust command path | simulated (`make mailbox`) |
| SHA-256, streaming SHA-256 | NIST test vectors | simulated (`make sha256 sha256-stream`) |
| measurement register (PCR) | extend-only measurement | simulated (`make pcr measure`) |
| XSEC unit | ISA hooks into the above | simulated (`make xsec`) |

These are building blocks. A host-writable volatile vault does not prove the
host never knew a key. A measurement register without immutable trust
anchors is not authenticated boot or attestation. See
[`docs/security/threat-model.md`](../security/threat-model.md).

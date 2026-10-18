# Heterogeneous system: CPU, GPU and TPU behind one job interface (proposed)

**Status: SPECIFICATION, with the GPU engine built and scheduled (2026-10-18).** The GPU runs real kernels over a HYDRA bank (`make gpu`) and is the chip's sixth dispatcher slot in simulation (`make systile-gpu`); ABI version 2 is built on the chip side (`sys/rtl/hydra_abi_v2.sv`): the header is checked, the engine policy and engine health become an eligibility mask, and the scheduler applies it before comparing costs; the CPU is not integrated. The
capability matrix is the record of what runs.

## Candidates, as inspected on 2026-10-11

| engine | repository and revision | license | what it is | interface facts that drive integration |
|---|---|---|---|---|
| CPU | `Normansrule/sixfold-cpu` @ `a642bd6` | MIT | 6-stage RV64IM + Zba/Zbb/Zbs, instruction and data caches, branch prediction | Top `riscv64_top` has **no external memory port**: programs enter a scratchpad through `$readmemh` from a plusarg, which is simulation-only. It needs a host-writable program and data port and a halt/done handshake before it can take jobs |
| GPU | `Normansrule/pixelstorm-gpu` @ `4801c8c` | MIT | SIMT, 2 SMs × 4 warps × 8 lanes, 40-instruction CUDA-style ISA | Top `ps_gpu_top` already has host instruction and constant write ports, `launch(grid, block)`, `done`, and a global-memory request/response port. That port connects to a HYDRA bank or DDR controller |
| TPU | this repository, `sys/rtl/hydra_engine_tpu_dma.sv` | (this repository's) | 4×4 INT8 array fed from scratchpad | integrated and simulated: commit barrier, refusal, bank ownership |

The vector unit stays a separate engine. It is not renamed GPU.

The CPU keeps its own instruction set. HYDRA submits a program address and
arguments; it does not reinterpret RV64 as anything else. The variable-latency
divider, caches and predictor are recorded as timing observables in the
threat model.

## Engine identifiers

The version-1 dispatcher has five slots: 0 CPU, 1 SIMD, 2 TPU, 3 NTT,
4 CRYPTO. A GPU needs a sixth slot. `ENG_N` grows to 6 and the cost-model
ROM gains a row. That changes the tile-shared modules, so it is a chip-side
change only. The Tiny Tapeout tile stays at five and is not affected.

## Descriptor ABI version 2 (proposed)

Version 1 is 128 bits with no room for these fields, and its reserved bits
are not reused. Version 2 adds a header word, and the version field makes a
v1 consumer refuse a v2 descriptor rather than misread it.

| field | bits | meaning |
|---|---|---|
| `abi_version` | 4 | 2 |
| `security_mode` | 2 | 0 PUBLIC_DEBUG, 1 FHE, 2 SE, 3 reserved (refused) |
| `engine_policy` | 3 | 0 AUTO, 1 CPU, 2 GPU, 3 TPU, 4 SIMD, 5 NTT, others refused |
| `context_id` | 8 | the context this job belongs to |
| `context_epoch` | 16 | must equal the current epoch, or the job is refused |
| `key_handle` | 8 | a key-vault slot or FHE evaluation-key set. Never key material |
| `profile_id` | 8 | FHE scheme and parameter set, or the SE profile |
| then the v1 body | 128 | operation class, data type, dimensions and bank addresses as today |

As built (2026-10-18): the header is the 64 bits above, MSB first, with the
remaining 15 bits reserved and required to be zero; `key_handle` and
`profile_id` must be zero in PUBLIC_DEBUG. Refusal codes: 1 version,
2 reserved bits, 3 security mode, 4 policy, 5 context or epoch, 6 key or
profile set, 7 no eligible engine; a job no eligible engine can perform is
refused by the scheduler itself. Headers, contexts and the healthy-engine
mask are loaded over the memory port (`hydra_sys_tile`, `ABI_V2 = 1`).

## Eligibility before cost

Engines are filtered **before** any cost is compared:

```
eligible = present && healthy
        && opclass_supported && dtype_supported
        && security_mode_supported(mode, profile)
        && context_owned(context_id, context_epoch)
        && (engine_policy == AUTO || engine_policy == this_engine)
```

If no engine is eligible, the job completes with a defined error status. It
does not fall back to an engine that cannot honour the mode. An explicit
engine request that fails eligibility gets the same error. Calibration is
kept per engine, operation, mode and parameter class, because a public INT8
measurement says nothing about an SE-authenticated kernel.

Version 1's host-side equivalent is `tools/hydra_host.py check_job`. It
admits only (PUBLIC_DEBUG, AUTO) and refuses everything else.

## Integration order (Gate C)

1. Validate the existing scheduler image on a physical board
   ([`docs/bringup/ulx3s-85f.md`](../bringup/ulx3s-85f.md)). The audit's work
   order puts this before integration, so that integration bugs are not
   mistaken for board bugs.
2. GPU first. Its host interface already matches the engine contract
   (load, launch, done, memory port). Required evidence: a real kernel
   computing over a HYDRA bank, the results checked against Pixelstorm's own
   model, completion only after the last global write, and refusal of a
   malformed launch. **Done in simulation, 2026-10-17** (`make gpu`: 14
   kernels; the four refusals; a bank-write watcher after done). The sixth
   dispatcher slot is built on the chip side (`NENG = 6`, `make systile-gpu`);
   ABI version 2 is built on the chip side too (`sys/rtl/hydra_abi_v2.sv`,
   `make abi-v2 systile-abi`); still to do: a board image.
3. CPU. Add a program and data load port and a done/halt handshake. Required
   evidence: a real program's results checked against Sixfold's model (the
   108 regression runs), with completion after the last store is visible.
4. Synthesise CPU + GPU + TPU + scheduler + bridge for the target board
   before claiming fit. ECP5-85F LUT4 counts are not comparable with AMD
   LUT6 counts.

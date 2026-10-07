# TPU — output-stationary INT8 systolic array

An engine the dispatcher can drive: present a descriptor on the engine port,
stream K operand slices, collect N×N results, get one completion with the tag.

## Files, one job each

| file | job |
|---|---|
| `rtl/tpu_pkg.sv` | sizes and the status enumeration |
| `rtl/tpu_pe.sv` | one processing element: multiply-accumulate, or shift during drain |
| `rtl/tpu_feeder.sv` | diagonal skew — lane *i* delayed by *i* so operands meet correctly |
| `rtl/tpu_array.sv` | the N×N grid; wiring only, no control |
| `rtl/tpu_drain.sv` | serialises a row of accumulators to a 32-bit stream |
| `rtl/tpu_ctrl.sv` | the only state machine: CLEAR → STREAM → FLUSH → DRAIN → TAIL → DONE |
| `rtl/tpu_top.sv` | engine port, descriptor decode, and the composition |
| `tb/tpu_model.py` | what the answer must be, written from the contract |
| `tb/tb_tpu.sv` | drives the port, stalls at random, compares every element |
| `formal/tpu_ctrl.sby` | the port contract, proved by k-induction |
| `formal/mutate_tpu.py` | nine deliberate breaks; each must be caught |

## Measured

| property | value | how |
|---|---|---|
| correctness | 40 cases, 640 results exact | against `tpu_model.py`, with random operand stalls |
| port contract | proved, depth 12 | `tpu_ctrl.sby`, five assertions |
| mutations | 8 killed, 1 survivor documented | `mutate_tpu.py` |
| ECP5 area (N=4) | 1,818 LUT4, 964 flops, 16 multipliers | `synth_ecp5` |
| latency | K + 2N − 2 + N·(N+1) cycles per tile | from the controller |

## Scope

One tile per descriptor: M and N up to the array edge, K unbounded. A larger
matrix multiply is several descriptors, which is how the dispatcher already
works. Hardware tiling needs an address generator and a partial-sum memory,
and that belongs in its own module rather than hidden in this one.

Operands arrive as K slices: slice k carries column k of A and row k of B —
what a direct memory access engine streaming from a scratchpad produces.

## Three bugs this found, all in the writing of it

1. **Completion before the results.** The controller signalled done while the
   last row was still inside the serialiser: 13 results instead of 16. Fixed
   with the TAIL state.
2. **Stalling slid the pipeline.** When the operand source paused, the skew
   registers and the array kept shifting, so operands lost alignment and the
   dot product was quietly wrong. Only the deep-K case with random stalls
   caught it; every shallow case passed.
3. **A synchronous flush in an asynchronous reset branch.** `if (!rst_n ||
   flush)` simulates correctly and is rejected by synthesis. The good outcome
   — the bad one is a tool that accepts it and infers a second asynchronous
   reset.

Plus one spare cycle: mutation testing shortened the flush and every test
still passed, which meant the flush was a cycle longer than the array needs.

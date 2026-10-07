# SIMD — 4-lane 32-bit vector unit

An engine the dispatcher can drive, with the same port shape as the TPU:
descriptor in, operand groups in, results out, one completion with the tag.

| file | job |
|---|---|
| `rtl/simd_pkg.sv` | widths, the status enumeration, and where the lane opcode lives |
| `rtl/simd_alu.sv` | one lane's arithmetic, combinational, eight operations |
| `rtl/simd_lanes.sv` | four lanes with one pipeline stage |
| `rtl/simd_reduce.sv` | lane adder plus accumulator, for reductions |
| `rtl/simd_serial.sv` | four results per group onto one 32-bit port |
| `rtl/simd_ctrl.sv` | the only state machine |
| `rtl/simd_top.sv` | engine port, descriptor decode, composition |
| `tb/simd_model.py` | the arithmetic, from the contract |
| `tb/tb_simd.sv` | every operation, both classes, random stalls, refusals |
| `formal/simd_ctrl.sby` | port contract, proved by k-induction |
| `formal/mutate_simd.py` | ten deliberate breaks |

## Operations

`ADD SUB MUL MAX MIN AND OR XOR`, chosen by descriptor bits **[2:0]** — the
reserved field. That is a real commitment, argued in `simd_pkg.sv`: the
descriptor has no opcode field, and a control register would race a
pipelined dispatcher. If `reserved` is ever allocated, this moves, and
tb_simd's opcode probe fails until it does.

`op_class` selects the shape: ELEMENT and SCALAR stream `dim_m` results,
REDUCE returns one. The element count is **`dim_m`**, and it must be a
multiple of the lane count — a partial group is refused, not padded.

## Measured

| property | value |
|---|---|
| correctness | 48 cases, 572 results exact against the model |
| port contract | proved, depth 14 |
| mutations | **10 killed, 0 survivors** |

## The bug worth keeping

The engine first read its element count from `dim_k`, while the dispatcher's
cost model prices ELEMENT work as `W = M`. The dispatcher was therefore
costing a four-element vector while the engine ran sixteen: every estimate
wrong by exactly the lane count, and the calibration loop would have spent
its life correcting a units mismatch rather than measuring hardware.

Nothing in the unit's own tests could see it — both sides were
self-consistent. It took putting two real engines behind the real
dispatcher and watching where the work actually went.

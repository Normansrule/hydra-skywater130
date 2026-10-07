# Scratchpad and operand streamer

The piece that makes the engines' operands real. Until now every engine
adapter fed its engine from a pattern generator with a comment admitting
the data was synthetic; this reads operands out of memory and writes the
results back.

| file | job |
|---|---|
| `rtl/hydra_spram.sv` | one scratchpad bank, inferred, registered read |
| `rtl/hydra_dma_agen.sv` | the address arithmetic, alone and testable |
| `rtl/hydra_dma_gemm.sv` | the streamer: memory to engine, results to memory |
| `tb/dma_model.py` | operands, bank layout and the expected product |
| `tb/tb_hydra_dma.sv` | load memory, dispatch, read results back out |
| `formal/hydra_dma_gemm.sby` | the streamer's contract, proved |
| `formal/mutate_dma.py` | thirteen breaks across both engines: **13 killed, 0 survivors** |

## Bank layout — a contract with whoever fills memory

    A bank, word k = a[0..3][k]   one byte per lane, lane 0 in bits [7:0]
    B bank, word k = b[k][0..3]

One word from each bank is a complete slice for a four-lane engine, so the
streamer needs no gather logic: the transpose was paid once, by the loader.
Lanes outside the tile are zeroed by the loader — the engine has no idea
which lanes are inside a tile and should not need to.

## Addresses in the descriptor

    wd[12:3]   base_a      wd[22:13]  base_b      wd[32:23]  base_c

Reserved bits, allocated the way the vector unit's opcode was, and
documented in both places because a later collision would be silent.

## Two bugs the proof found that simulation could not

**A zero-length job wrapped the counter.** `k_slices = 0` decremented from
zero to 65,535 and the streamer read memory until the next dispatch
rescued it. Invisible in simulation because the engine refuses such a
descriptor anyway — the streamer should not depend on that.

**An operand was offered during the memory-latency wait.** Also invisible:
the array happens to be clearing its accumulators for exactly that cycle,
so it never takes the early word. A coupling between two modules' timing
is not a guarantee; an engine that asserted ready immediately would have
received whatever the bank held before the job.

Both were found because the mutations for them *survived* the simulation
suite, which is what mutation testing is for.

## One mistake worth recording

The first version of this proof **assumed** the counter was non-zero
mid-stream, to get induction past an unreachable state. That assumption
hid the zero-length wrap: the bug was inside the thing being assumed away.
The invariant is now asserted across both active states instead, and the
power-up state is constrained honestly with `initial assume (!rst_n)`
rather than by weakening the property.


## The streamer's third and fourth bugs, from the vector unit

Feeding the vector unit exposed what the array never could, because the
array takes a group every cycle and the vector unit stalls four:

**The prefetched word was lost during a stall.** The bank reads every
cycle; its output holds the word for last cycle's address. The streamer
advanced the address as soon as a group was consumed, so during a stall the
next word overwrote the one waiting. Fixed with a holding register and one
rule: when the held word is not being taken, present the SAME address
again so the bank keeps outputting it.

**The first fix hung.** It captured in the wait state, before the bank had
answered, and counted that phantom capture against the job — so the last
group was never fetched.

The proof then found two more: a start arriving during DRAIN reloaded the
address generator while the state machine ignored it, and the result count
was read live from the descriptor for the whole job — a descriptor that
arrives on the crossbar's shared bus. Both are fixed; adapters now refuse
work while the streamer is busy.

Mutation testing found the last one in the TEST: jobs were packed
contiguously, so the stale word left on the bank after one job was exactly
the next job's first operand, and a streamer that skipped the latency wait
read a wrong word that happened to be right. Jobs are now separated by
poisoned gaps.

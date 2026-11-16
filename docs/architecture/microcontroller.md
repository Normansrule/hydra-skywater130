# The HYDRA-130 microcontroller (OpenFrame chip, `MCU = 1`)

Status: **simulated through the chip's pads** (2026-10-25). Not hardened and not on a board. The Tiny Tapeout tile is unaffected and stays scheduler-only.

`sky130/rtl/hydra_openframe_top.sv` has two builds. With `MCU = 0` it holds the scheduler tile, as it has since v1. With `MCU = 1` it holds the system tile (`sys/rtl/hydra_sys_tile.sv`), turning the chip into a small microcontroller with a hardware dispatcher.

## What is inside

| Block | What it does | Source |
|---|---|---|
| Scheduler (MOM) | cost model over five slots, tags, calibration, ABI version 2 front end | `mom/rtl`, `sys/rtl/hydra_abi_v2.sv` |
| CPU | Sixfold RV64IM (unchanged) with its 4 KiB instruction and data caches | `ext/sixfold-cpu`, `sys/rtl/hydra_engine_cpu.sv` |
| CPU memory | 16 KiB in eight SkyWater 130 SRAM macros (OpenRAM `sky130_sram_2kbyte_1rw1r_32x512_8`) | `sys/rtl/hydra_cpu_sram.sv` |
| Secure boot | the CPU runs only the image whose SHA-256 equals the mask's digest | `sec/rtl/hydra_secure_boot.sv`, [secure-boot.md](secure-boot.md) |
| Dispatch port | the running program hands work to the scheduler | `hydra_engine_cpu.sv`, `hydra_sys_tile.sv` |
| TPU | 4×4 INT8 systolic array (pattern-fed in this build) | `engines/tpu` |
| Vector unit | 4-lane INT8/16 unit | `engines/simd` |
| I2C target + host bus | two wires load and read the whole chip; 15 GPIO | `common/rtl/hydra_i2c_gpio.sv` |
| SPI register map | the scheduler's host interface, as on the tile | `mom/rtl/hydra_tt_regs.sv` |

The GPU (Pixelstorm, about 62,600 LUT4 on an FPGA) stays FPGA-only in this build, because of area.

## Pads

The pads are the same as the scheduler build (see [../pins.md](../pins.md)):
- **3 to 26:** the system tile's SPI and status pins.
- **27 and 28:** I2C.
- **29 to 43:** GPIO.

The only difference is the I2C host bus: in this build it drives the system tile's memory port.

## Loading and starting a program over two wires

The I2C target is at address `0x2A`.
1. Write the bank and address registers: 0x10 is the bank, with bit 7 meaning hold the address; 0x11 and 0x12 are the address. Then stream 32-bit words into 0x13 to 0x16. Bank 3 is the system tile's control space.
2. Control offset 6 sets the CPU word address. Offset 7, written with the address held, streams the program into the CPU memory.
3. Offset 8 sets the entry point. Offset 11 sets the boot length. A write to offset 12 boots. Offset 5 reads the boot status.
4. Load the ABI version 2 header (offsets 2 and 3) and a context (offset 4). Then send a descriptor over SPI. The scheduler sends scalar work to the CPU.

## The dispatch port (the CPU as a client of the scheduler)

A running program reaches these 64-bit registers in Sixfold's device page:

| Address | Access | Meaning |
|---|---|---|
| `0x1000_0100` | W | descriptor [63:0] |
| `0x1000_0108` | W | descriptor [127:64] |
| `0x1000_0110` | W | ABI version 2 header |
| `0x1000_0118` | W | any store: offer the descriptor to the scheduler |
| `0x1000_0120` | R | [0] waiting, [15:8] refused, [19:16] last refusal code, [31:24] dispatched, [47:32] completed, [63:48] tags still outstanding |

The CPU goes first when the host and the CPU offer work in the same cycle. The CPU is never eligible for work it submits itself, so a program cannot wait on a job queued behind itself. Such a job is refused by the ABI front end with code 7, "no eligible engine".

## Memory size and the 64 KiB address space

Sixfold addresses 64 KiB. The chip has 16 KiB, which appears four times in that space. All 24 Sixfold programs fit in it, including the two whose stack starts at `0xF000`: it lands at `0x3000`, in free memory. Measured with Sixfold's model (`make cpu-sram MEM=16384`, below).

## Area (yosys, typical corner, before placement)

| Block | Cells | Area |
|---|---|---|
| CPU with caches, logic only | 182,007 | 3.14 mm² |
| of which the caches' flip-flops | 75,076 | (most of it) |
| 8 SRAM macros | 8 | 2.28 mm² (683 × 417 µm each) |

A cache-size parameter in Sixfold (default unchanged) would cut the CPU's logic to roughly a quarter. That needs a change to the Sixfold repository and is waiting for the owner's OK.

## Evidence

| Check | What it shows | Command |
|---|---|---|
| CPU on SRAM macros | all 24 Sixfold programs give the cached model's registers, TOHOST and cycle count, on the PDK's own Verilog model of the macro, with 8 macros (16 KiB) and with 32 (64 KiB) | `make cpu-sram MEM=16384`, `make cpu-sram MEM=65536` |
| The chip through its pads | program loaded over I2C; an unbooted CPU takes no work; secure boot verifies with hashlib's digest; a scalar job sent over SPI runs on the CPU to Sixfold's TOHOST; registers locked afterwards | `make sky130-mcu` |
| Dispatch port | a program on the CPU hands a matrix multiply to the TPU (descriptor bit for bit), waits for its completion, and is refused work for itself (code 7) | `make systile-disp` |
| I2C host bus | 400 random transactions against an independent model, including bursts, held addresses and read-back | `make i2c-gpio` |
| Lint | Verilator `-Wall`, 0 warnings on 5.032 and 5.051, for the tile, both chip builds and the six-slot system tile; only the unchanged third-party submodules are waived | `make lint` |
| Mutations | I2C-01 to I2C-09, PAD-01 and 02, SB-01 to SB-09, DP-01 to DP-04 | `python3 tools/mutate_mom.py` |

## Not done yet

- **No harden.** The OpenFrame chip, in either build, has never been placed and routed, so there are no DRC, LVS or timing numbers for it.
- **No board run.**
- **CPU on the TPU's memory.** The CPU cannot yet read or write the TPU's scratchpads, so a program cannot move data to an engine itself. The host does that over the memory port.
- **FHE.** Fully homomorphic encryption stays a specification, and the host refuses it ([heterogeneous-system.md](heterogeneous-system.md)).

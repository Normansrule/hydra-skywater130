# HYDRA-130 against the Baremetal-IDE lab

Reference: UC Berkeley EE290C, *Baremetal IDE Lab*
(https://ucb-ee290c.github.io/tutorials/baremetal-ide/Baremetal-IDE-Lab.html),
read on 2026-11-07. The lab builds C programs with CMake and the RISC-V GCC
for a Rocket core on an FPGA-emulated chip (SophiaLake), loads them over
UART-TSI or JTAG, and debugs them with OpenOCD and GDB. Below, each step of
that flow is mapped onto HYDRA's CPU slot (Sixfold RV64, `sys/rtl/hydra_engine_cpu.sv`)
and classified. Every number comes from tool output on 2026-11-07.

Run it: `make baremetal` (needs `riscv64-unknown-elf-gcc`; without a PDK,
`make sram-model` first).

| lab step | HYDRA equivalent | status | evidence |
|---|---|---|---|
| RISC-V GCC toolchain | `riscv64-unknown-elf-gcc` 14.2.0, `-march=rv64im_zba_zbb_zbs_zicsr -mabi=lp64` (the extensions Sixfold implements; libgcc from the rv64im/lp64 multilib) | WORKING | `make baremetal` builds with `-Wall -Wextra -Werror` |
| platform folder, `chip_config.h` | `sw/baremetal/hydra_cpu.h`: RAM, reset PC 0x2000, putchar, LEDs, buttons, MTIME/MTIMECMP, the dispatch port, TOHOST; each address taken from `model/core.js` and the wrapper's RTL | WORKING (new) | addresses cited in the header |
| linker script | `sw/baremetal/link.ld`: 0x2000-0x3FFF, stack down from 0x4000, so one image fits the chip's 16 KiB of SRAM macros and the 64 KiB simulation memory; an `ASSERT` refuses an image that does not fit | WORKING (new) | `hello.elf`: text 791, data 16, bss 32 bytes |
| startup code | `sw/baremetal/crt0.S`: gp, sp, mtvec, `.bss` cleared, `main()`, its return value to TOHOST as `(r << 1) \| 1`; a trap ends the job with `mcause` | WORKING; the trap path is written but not exercised by a test | `hello.c` reads a `.bss` array and folds it into its result |
| build | `make baremetal` | WORKING | |
| expected printout ("Hello World") | `hello.c` prints a greeting, `fib(60)`, a CRC-32 of the greeting and a 64-bit divide check; `sw/baremetal/hello.expect` holds the expected text and the Makefile recomputes it in Python (`zlib.crc32`) | WORKING in Sixfold's model: the console matches `hello.expect` | model: TOHOST 0x3b1f390b, main returned 0x1d8f9c85, as Python computes; a one-digit change to `hello.expect` fails the check (exit 1) |
| run on the hardware | the same image on three RTL builds, compared register for register and cycle for cycle with Sixfold's model: flat memory (3,763 cycles), Sixfold's 4 KiB caches (3,907), the chip's 8 SkyWater 130 SRAM macros with 1 KiB caches (3,907) | WORKING in simulation (Icarus Verilog) | `PASS tb_hydra_engine_cpu ... 10 checks` three times; `PASS baremetal` |
| console on the hardware (UART) | since v67 a PUTCHAR store queues the byte for an 8N1 UART transmitter on the CPU's `uart_tx` pin (16-byte queue, `UART_STATUS` to poll, `UART_DIV` clocks per bit); on the chip, I2C OWNER[0] puts it on pad 29 | WORKING in simulation | `make cpu-uart`: 5 printing programs decoded from the pin equal to the model's console; `make baremetal`: on the whole chip, `hello.c` loaded over I2C and secure-booted printed 121 bytes on pad 29, equal to the model's; mutations UART-01 to 04, PAD-03 |
| GPIO (blinky, buttons) | since v67 the LEDS register (16 bits) drives `gpio_out` and BUTTONS reads `gpio_in`; on the chip, I2C OWNER[1] puts LEDS bits 0-13 on pads 30-43, and the CPU reads all 15 GPIO pads | WORKING in simulation (LEDs); buttons are wired and read 0 in every test, so their read path is not yet checked against a pressed button | `hello.c` and `hydra_leds_uart.s` set LEDS to 0x2A5C: the wrapper's pins and the chip's pads show it; mutation LED-01 |
| timer (CLINT) | MTIME (counts every clock) and MTIMECMP, with timer interrupts | WORKING in simulation | Sixfold's `21_timer_interrupts` passes in `make cpu`, `cpu-cached` |
| interrupt controller (PLIC) | none | MISSING | |
| loading a program (PyUARTSI / GDB `load`) | the host writes the CPU's memory through the SPI control space (bank 3) or, on the microcontroller build, over I2C, then secure boot checks its SHA-256 | WORKING in simulation | `make systile-cpu`, `make sky130-mcu` (I2C load, secure boot, SPI job) |
| FPGA image running the program | no FPGA image includes the CPU (no `plans/*.yaml` sets `CPU_ENGINE`, whose default is 0); the cached CPU maps to ECP5 cells (`make cpu-synth`) but is not placed | MISSING | |
| JTAG + OpenOCD + GDB debug | Sixfold has no RISC-V debug module (no DTM, no abstract commands; `ebreak` traps to `mtvec`); HYDRA's JTAG is a test access port for the scheduler bridge (`make jtag`), not the RISC-V debug interface; OpenOCD is not installed here | DEFERRED WITH TECHNICAL JUSTIFICATION: the plan, in four steps with the evidence each needs, is `docs/architecture/cpu-debug.md` | `ext/sixfold-cpu/src/` has no debug module |
| board run | no board has run any HYDRA image | BLOCKED BY MISSING EVIDENCE | |

## Against a 16 nm tapeout write-up

Reference: the 16 nm tapeout write-up at
https://yashck.github.io/project/tapeout-16nm-cmos-chip, read on
2026-11-07: two Berkeley RISC-V SoCs (Chipyard, Shuttle cores with Saturn
vector units, I2C, SPI, UART and JTAG), Cadence and Synopsys tools under
HAMMER, "synthesis, place and route, drc, lvs, and signoff", 500 MHz met.
The page has no bring-up results (its bring-up page was not read). It is a
reference for the steps, not for numbers: Intel 16 nm is not an open PDK.

| step | HYDRA | status |
|---|---|---|
| RTL composed and simulated | yes, open simulators (Icarus, Verilator), every block against an independent model | WORKING |
| bare-metal C tests | `make baremetal` (above) | WORKING in simulation |
| synthesis, place and route, DRC, LVS, antenna, timing | Tiny Tapeout tile v3.12: DRC, LVS, antenna 0, every corner met at 66 ns | WORKING (tile) |
| the same for the full chip | the microcontroller core: run 3 routed with LVS 0 and 0 DRC outside the SRAM macros but failed setup by 14.85 ns at the slow corner at 50 ns; run 4 at 70 ns (LVS 0) still failed by 13.37 ns, its slowest path running through 36 weak delay cells; run 5 excludes them, as the tile did, and meets setup at every corner (+3.25 ns slow); open: hold −0.049 ns, 9 antenna nets, DRC on the full layout | BLOCKED (not signed off) |
| I2C, SPI, UART, JTAG | I2C target and SPI on the chip; the CPU's UART on pad 29 (v67); JTAG for the scheduler bridge on the FPGA images only, no RISC-V debug | partly MISSING (debug) |
| bring-up board and first-silicon tests | none | BLOCKED BY MISSING EVIDENCE |

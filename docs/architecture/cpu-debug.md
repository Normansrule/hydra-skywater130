# CPU debug over JTAG (plan, 2026-11-09)

**Status: DEFERRED WITH TECHNICAL JUSTIFICATION.** Nothing here is built.
This page plans what the Baremetal-IDE lab does with OpenOCD and GDB
(`target extended-remote`, `monitor reset halt`, `load`, breakpoints,
`continue`) for HYDRA's CPU slot, and says why it is not done yet.

## What exists

- Sixfold has no debug module: no debug transport module (DTM), no `dcsr`
  or `dpc`, no debug mode. `ebreak` traps to `mtvec` (mcause 3).
- HYDRA's wrapper already gives a host what a debugger needs most: load and
  read the CPU's memory (`ld_*`, `rd_*`), read any register while the core
  is halted (`dbg_reg`, `dbg_data`), set the entry address, start a job, and
  a cycle limit that stops a runaway program. On the chip these are reached
  over SPI (bank 3) or I2C (the host bus), and secure boot locks them after a
  verified boot.
- The JTAG tap in this repository (`make jtag`, `make jtag-bridge`) is an
  IEEE 1149.1 tap for the scheduler bridge on the FPGA images. It is not the
  RISC-V debug transport.
- OpenOCD is not installed on the development machine, so no OpenOCD flow
  can be checked yet.

## The plan, smallest useful step first

1. **System bus access (SBA) only.** A RISC-V Debug Module (External Debug
   Support 0.13.2) with `sbcs`, `sbaddress0`, `sbdata0` mapped onto the
   wrapper's existing load and read ports, `dmstatus` reporting `allhalted`
   whenever the core is not running a job, and `haltreq` mapped onto the
   cycle-limit stop. OpenOCD and GDB can then `load` a program and read
   memory, which is the lab's load step. No Sixfold change.
2. **Abstract register reads.** The Access Register command (`regno`
   0x1000-0x101F) served from the existing debug read port, read only.
   GDB can then show registers after a halt (`info registers`).
3. **Halt, resume, step, register writes, breakpoints.** These need debug
   mode inside Sixfold: freeze the pipeline at an instruction boundary, save
   the PC in `dpc`, `dcsr.step`, a register-file write port, and `ebreak`
   entering debug mode when `dcsr.ebreakm` is set. That is a change to the
   Sixfold repository, checked against its cycle-exact model, which would
   need the same debug mode.
4. **Pins.** Every one of the chip's 44 pads is in use. JTAG (TCK, TMS, TDI,
   TDO) would take four GPIO pads through the I2C OWNER register, as the
   CPU's UART does on pad 29.

## Why not now

- Steps 3 and 4 change the CPU core and the pin plan. Step 3 also changes
  Sixfold's model, so every one of its 162 regression runs and HYDRA's 25
  CPU vectors would have to be regenerated and rechecked.
- No result can be shown without OpenOCD connecting to it. That needs
  OpenOCD installed and a debug-transport model in simulation (OpenOCD's
  `remote_bitbang` driver against a Verilator build) before any board.
- The console UART, LEDs and buttons (v67) already cover the lab's printout
  and blinky steps, and the host ports cover loading. Debug is the remaining
  gap.

## What would close it

| step | evidence required |
|---|---|
| 1 | OpenOCD (remote_bitbang into a Verilator simulation) examines the target and `load`s `hello.elf`; the memory read back equals the ELF |
| 2 | GDB `info registers` after a job equals Sixfold's model's registers |
| 3 | GDB breakpoint, `stepi` and `continue` on `hello.c`, the console still equal to `hello.expect`; Sixfold's regression unchanged with debug off |
| 4 | the chip simulated through its pads with OpenOCD on four GPIO pads |

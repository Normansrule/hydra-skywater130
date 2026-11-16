#!/bin/bash
# regen.sh -- the core's sources as one Verilog file for LibreLane, as the
# tile's src/regen.sh does: sv2v over the SystemVerilog, SYNTHESIS defined.
set -euo pipefail
cd "$(dirname "$0")/../../.."
SF=ext/sixfold-cpu
SIX=$(sed "s|^|$SF/|" $SF/src/sources.f | grep -v -e Riscv64_top.sv -e Scratchpad_Memory.sv)
sv2v -DSYNTHESIS $SIX $SF/fpga/rtl/Main_Memory.sv   mom/rtl/mom_pkg.sv $(ls mom/rtl/*.sv | grep -v mom_pkg) common/rtl/mom_xbar.sv   engines/tpu/rtl/tpu_pkg.sv $(ls engines/tpu/rtl/*.sv | grep -v pkg)   engines/simd/rtl/simd_pkg.sv $(ls engines/simd/rtl/*.sv | grep -v pkg) mem/rtl/*.sv   sec/rtl/hydra_sha256.sv sec/rtl/hydra_sha256_stream.sv sec/rtl/hydra_measure.sv sec/rtl/hydra_secure_boot.sv   sys/rtl/hydra_engine_tpu.sv sys/rtl/hydra_engine_simd.sv sys/rtl/hydra_engine_tpu_dma.sv   sys/rtl/hydra_cpu_sram.sv sys/rtl/hydra_engine_cpu.sv sys/rtl/hydra_abi_v2.sv sys/rtl/hydra_sys_tile.sv   sky130/rtl/hydra_mcu_core.sv

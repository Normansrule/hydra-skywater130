#!/bin/bash
# lint.sh -- Verilator --lint-only -Wall on what gets hardened, with the
# settings LibreLane's linter uses (DECLFILENAME and EOFNEWLINE off).
#
#   1. the Tiny Tapeout tile's submitted netlist, tt/tile/src/project.v,
#      exactly as LibreLane lints it: no waivers;
#   2. the SkyWater OpenFrame chip, generated the same way (sv2v, then the
#      unused-constant filter), with the waivers in tools/lint/waivers.vlt.
#
# Fails on any warning. The FPGA images are built by Yosys and are not
# covered here.
set -euo pipefail
cd "$(dirname "$0")/../.."
T="${SIMTMP:-$(mktemp -d)}"
mkdir -p "$T"
V=(verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-EOFNEWLINE)
fail=0

run() {  # label, top, files...
  local label=$1 top=$2; shift 2
  local log="$T/lint_$label.log"
  if "${V[@]}" --top-module "$top" "$@" >"$log" 2>&1 && ! grep -q '^%' "$log"; then
    echo "  clean  $label ($top)"
  else
    echo "  FAIL   $label ($top): $(grep -c '^%Warning' "$log" || true) warnings, log $log"
    grep '^%' "$log" | head -20
    fail=1
  fi
}

run tile tt_um_hydra_mom tt/tile/src/project.v

sv2v mom/rtl/*.sv mom/hydra_mom_pins.sv common/rtl/hydra_rst_sync.sv \
     common/rtl/hydra_padmux.sv common/rtl/hydra_i2c_gpio.sv sky130/rtl/hydra_openframe_top.sv |
  python3 tools/lint/sv2v_clean.py > "$T/openframe_lint.v"
run openframe openframe_project_wrapper tools/lint/waivers.vlt "$T/openframe_lint.v"

# 3. the microcontroller build of the chip (MCU = 1): scheduler, Sixfold CPU on
#    SRAM (the macro's model here), secure boot, TPU, vector unit, I2C host
#    bus. Linted from the SystemVerilog sources directly; only the unchanged
#    third-party submodules are waived (tools/lint/waivers_thirdparty.vlt).
SF=ext/sixfold-cpu
if [ -f $SF/src/sources.f ]; then
  SIX=$(sed "s|^|$SF/|" $SF/src/sources.f | grep -v -e Riscv64_top.sv -e Scratchpad_Memory.sv)
  MCU_F="mom/rtl/mom_pkg.sv $(ls mom/rtl/*.sv | grep -v mom_pkg) mom/hydra_mom_pins.sv     common/rtl/hydra_rst_sync.sv common/rtl/hydra_padmux.sv common/rtl/hydra_i2c_gpio.sv common/rtl/mom_xbar.sv     engines/tpu/rtl/tpu_pkg.sv $(ls engines/tpu/rtl/*.sv | grep -v pkg)     engines/simd/rtl/simd_pkg.sv $(ls engines/simd/rtl/*.sv | grep -v pkg) mem/rtl/*.sv     sec/rtl/hydra_sha256.sv sec/rtl/hydra_sha256_stream.sv sec/rtl/hydra_measure.sv sec/rtl/hydra_secure_boot.sv     sys/rtl/hydra_engine_tpu.sv sys/rtl/hydra_engine_simd.sv sys/rtl/hydra_engine_tpu_dma.sv     sys/rtl/hydra_cpu_sram.sv sys/rtl/hydra_engine_cpu.sv sys/rtl/hydra_abi_v2.sv sys/rtl/hydra_sys_tile.sv     sky130/rtl/hydra_openframe_top.sv"
  run mcu openframe_project_wrapper -GMCU=1 -GMCU_SRAM_MODEL=1 tools/lint/waivers_thirdparty.vlt     $SIX $SF/fpga/rtl/Main_Memory.sv $MCU_F
  # 4. the six-slot system tile with every real engine (the configuration the
  #    system benches run): CPU, memory-fed TPU, vector unit, GPU, ABI v2,
  #    secure boot -- so a port that only one personality connects is linted too
  PS=ext/pixelstorm-gpu/rtl
  run systile hydra_sys_tile -GNENG=6 -GTPU_ENGINE=2 -GSIMD_ENGINE=1 -GGPU_ENGINE=1 -GABI_V2=1     -GCPU_ENGINE=1 -GSECURE_BOOT=1 -GCPU_CACHED=1 -GCPU_SRAM=1 -GCPU_SRAM_MODEL=1 -GCPU_MEM_BYTES=16384     -I$PS tools/lint/waivers_thirdparty.vlt $SIX $SF/fpga/rtl/Main_Memory.sv $PS/ps_*.v     $(echo $MCU_F | sed 's|sky130/rtl/hydra_openframe_top.sv||') sys/rtl/hydra_engine_gpu.sv
else
  echo "  FAIL   mcu: $SF missing (git submodule update --init)"; fail=1
fi

# 5. the tile's project.v with the Verilator the Tiny Tapeout GDS action uses
#    (5.018, in efabless/openlane:latest). Newer releases accepted a reset loop
#    that 5.018 rejects (BLKLOOPINIT), and the action failed for nine days
#    before anyone saw it (2026-10-18 .. 27). Any %Error fails here.
if command -v docker > /dev/null && docker image inspect efabless/openlane:latest > /dev/null 2>&1; then
  log="$T/lint_tile_518.log"
  docker run --rm -v "$PWD/tt/tile/src:/w:ro" --entrypoint /bin/sh efabless/openlane:latest     -c 'verilator --version; verilator --lint-only -Wno-fatal --top-module tt_um_hydra_mom /w/project.v' > "$log" 2>&1 || true
  if grep -q '^%Error' "$log"; then
    echo "  FAIL   tile under the GDS action's $(head -1 "$log" | cut -c1-16): $(grep -c '^%Error' "$log") errors, log $log"
    grep '^%Error' "$log" | head -5; fail=1
  else
    echo "  clean  tile under the GDS action's $(head -1 "$log" | cut -c1-16) (no errors)"
  fi
else
  echo "  skip   tile under Verilator 5.018: docker image efabless/openlane:latest not present"
fi

if [ $fail -ne 0 ]; then echo "FAIL lint"; exit 1; fi
echo "PASS lint: tile netlist, OpenFrame chip, its microcontroller build and the six-slot system tile are Verilator -Wall clean"

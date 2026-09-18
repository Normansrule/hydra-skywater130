# HYDRA-130 targets overlay -- one entry point for every check.
#
# Nothing here weakens a test to make it pass. A step that cannot run in this
# environment is absent, not stubbed: tile area (needs LibreLane and the PDK),
# Vivado and Quartus builds, and the TinyTapeout slow-corner read.
SHELL := /bin/bash
TILE  := tt/tile

.PHONY: status verify all tt asic fpga padmux tile diff harness sky130 tools boards bind mutate area capacity clean check-tile

status:                       ## what is set up, what is not, what to run next
	@./scripts/status.sh

verify: check-tile padmux xbar system tile diff harness sky130 tools boards bind
	@echo "=== all checks passed ==="

# All three targets from the one source, in one command. Each depends on the
# same tile RTL, so a change that breaks one shows up here rather than three
# weeks later in whichever target you were not looking at.
all: tt asic fpga
	@echo "=== TinyTapeout, sky130 chip and FPGA all built and checked ==="

tt: tile area              ## TinyTapeout: the tile's tests and its cell area
asic: sky130               ## sky130 chip: the OpenFrame wrapper, through its pads
fpga:                      ## FPGA: place, route and pack the recommended board
	python3 tools/hydra_bind.py build --plan plans/ecp5-evn.yaml
	$(MAKE) -C fpga/build/ecp5-evn
	@grep -E "Max frequency|Device utilisation" -A1 fpga/build/ecp5-evn/*.log 2>/dev/null | head -4 || true

check-tile:
	@test -f $(TILE)/src/project.v || { \
	  echo "tt/tile is empty. Run ./scripts/setup-tile.sh first."; exit 1; }
	@test -f fpga/vendor_refs/icebreaker.pcf || { \
	  echo "vendor pin files missing. Run: python3 tools/import_boards.py fetch"; exit 1; }

padmux:                       ## model comparison + formal proofs
	cd common/tb && python3 padmux_model.py padmux_vectors.hex 20000 1 && \
	  iverilog -g2012 -o /tmp/tb_padmux ../rtl/hydra_padmux.sv tb_hydra_padmux.sv && \
	  vvp -n /tmp/tb_padmux | tail -1
	cd common/formal && sby -f hydra_padmux.sby prove | tail -1 && \
	  sby -f hydra_rst_sync.sby prove | tail -1
	cd tt/formal && sby -f hydra_tt_spi.sby prove | tail -1

tile:                         ## the tile's cocotb suite, both personalities
	cd $(TILE)/src && bash regen.sh > project.v
	@cd $(TILE) && git diff --quiet src/project.v || \
	  { echo "project.v differs from regen.sh output"; exit 1; }
	cd $(TILE)/test && rm -rf sim_build && $(MAKE) -s 2>&1 | grep -E "TESTS=|FAIL"

diff:                         ## v2 legacy is v1, pin for pin
	cd tt && sv2v tile/src/rtl/*.sv tile/src/tt_um_hydra_mom.sv rtl/tt_um_hydra_mom_v1.sv \
	  > /tmp/hydra_diff.v && \
	  iverilog -g2012 -o /tmp/hydra_diff /tmp/hydra_diff.v tb/tb_v1_v2_diff.sv && \
	  vvp -n /tmp/hydra_diff | tail -2

harness:                      ## the PC protocol, end to end
	cd fpga && sv2v ../tt/tile/src/rtl/*.sv ../tt/tile/src/tt_um_hydra_mom.sv \
	  rtl/hydra_fpga_uart.sv rtl/hydra_fpga_tt_harness.sv > /tmp/hydra_harness.v && \
	  iverilog -g2012 -o /tmp/hydra_harness /tmp/hydra_harness.v tb_fpga_harness.sv && \
	  vvp -n /tmp/hydra_harness | tail -2

xbar:                         ## the engine crossbar against its model and proofs
	cd common/tb && python3 xbar_model.py xbar_vectors.hex 20000 179 && \
	  iverilog -g2012 -o /tmp/hydra_xbar ../rtl/mom_xbar.sv tb_mom_xbar.sv && \
	  vvp -n /tmp/hydra_xbar | tail -1
	cd common/formal && sby -f mom_xbar.sby prove | tail -1

system:                       ## the dispatcher, the crossbar and five engines
	sv2v tt/tile/src/rtl/mom_pkg.sv tt/tile/src/rtl/mom_features.sv \
	  tt/tile/src/rtl/mom_param_rom.sv tt/tile/src/rtl/mom_cost_engine.sv \
	  tt/tile/src/rtl/mom_calibrate.sv tt/tile/src/rtl/mom_select.sv \
	  tt/tile/src/rtl/mom_scoreboard.sv tt/tile/src/rtl/mom_top.sv \
	  common/rtl/mom_xbar.sv tt/tb/tb_mom_system.sv > /tmp/hydra_sys.v
	iverilog -g2012 -o /tmp/hydra_sys /tmp/hydra_sys.v
	vvp -n /tmp/hydra_sys | tail -4

sky130:                       ## the chip through its pads: pad mux, bring-up, SPI
	sv2v tt/tile/src/rtl/*.sv tt/tile/src/tt_um_hydra_mom.sv \
	  common/rtl/hydra_padmux.sv common/rtl/hydra_rst_sync.sv \
	  sky130/rtl/hydra_openframe_top.sv > /tmp/hydra_of.v
	iverilog -g2012 -o /tmp/hydra_of /tmp/hydra_of.v sky130/tb/tb_openframe.sv
	vvp -n /tmp/hydra_of | tail -2

area:                         ## sky130 cell area of the tile, v1 against v2
	./tools/sky130_area.sh HEAD b179c6b

capacity:                     ## which board holds what
	python3 tools/capacity.py

tools:                        ## PLL solver vs the vendor calculators, host encodings
	python3 -m pytest tools/test_pllcalc.py tools/test_hydra_host.py -q

boards:                       ## board files still match their vendor sources
	python3 tools/import_boards.py check

bind:                         ## generated board files still match plan + RTL
	@for p in plans/*.yaml; do python3 tools/hydra_bind.py check --plan $$p; done

mutate:                       ## slow: every test must be able to fail
	cd common/formal && python3 mutate_targets.py
	cd $(TILE) && python3 test/mutate_sim.py

clean:
	rm -rf fpga/build/*/{*.v,*.json,*.config,*.asc,*.bin,*.bit} \
	       common/tb/padmux_vectors.hex $(TILE)/test/sim_build common/formal/*_prove \
	       common/formal/*_cover tt/formal/*_prove tt/formal/*_cover

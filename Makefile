# HYDRA-130 targets overlay -- one entry point for every check.
#
# Nothing here weakens a test to make it pass. A step that cannot run in this
# environment is absent, not stubbed: tile area (needs LibreLane and the PDK),
# Vivado and Quartus builds, and the TinyTapeout slow-corner read.
SHELL := /bin/bash
TILE  := tt/tile

.PHONY: status verify padmux tile diff harness tools boards bind mutate clean check-tile

status:                       ## what is set up, what is not, what to run next
	@./scripts/status.sh

verify: check-tile padmux tile diff harness tools boards bind
	@echo "=== all checks passed ==="

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

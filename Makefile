# HYDRA-130 targets overlay -- one entry point for every check.
#
# Nothing here weakens a test to make it pass. A step that cannot run in this
# environment is absent, not stubbed: tile area (needs LibreLane and the PDK),
# Vivado and Quartus builds, and the TinyTapeout slow-corner read.
SHELL := /bin/bash
# pipefail: recipes like `sby ... | tail -1` and `vvp ... | grep PASS` must fail
# when the tool fails. Without it the pipe returned tail's status, so a missing
# sby, a failed proof or a $fatal testbench all passed `make verify` (found
# 2026-10-06, when sby was absent and verify stayed green on every proof).
.SHELLFLAGS := -o pipefail -c
TILE  := tt/tile

.PHONY: status provenance verify all tt asic fpga padmux tile diff harness sky130 tools boards bind mutate area capacity clean check-tile

status:                       ## what is set up, what is not, what to run next
	@./scripts/status.sh

provenance:                   ## which board bitstreams were built from the current sources
	@for d in fpga/build/*/; do grep -q '^provenance:' $$d/Makefile 2>/dev/null || continue; \
	  $(MAKE) -s --no-print-directory -C $$d provenance 2>/dev/null || true; done

verify: site-check tt-ready rst-sync-copy basys3-selftest check-tile cost-mux keyvault mailbox sha256 pcr selftest xsec jtag jtag-bridge padmux xbar tpu simd ntt ntt-moduli dma dma-simd dma-ntt memboard system systile systile-tpu systile-two tile diff harness sky130 tools boards bind isa-check
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
	python3 tools/hydra_bind.py build --plan plans/ecp5-evn-sys.yaml
	python3 tools/hydra_bind.py build --plan plans/ecp5-evn-tpu.yaml
	python3 tools/hydra_bind.py build --plan plans/ecp5-evn-two.yaml
	python3 tools/hydra_bind.py build --plan plans/ecp5-evn-mem.yaml
	$(MAKE) -C fpga/build/ecp5-evn
	$(MAKE) -C fpga/build/ecp5-evn-sys
	$(MAKE) -C fpga/build/ecp5-evn-tpu
	$(MAKE) -C fpga/build/ecp5-evn-two
	$(MAKE) -C fpga/build/ecp5-evn-mem
	@grep -E "Max frequency" fpga/build/ecp5-evn*/*.log 2>/dev/null | tail -4 || true

check-tile:
	@test -f $(TILE)/src/project.v || { \
	  echo "tt/tile is empty. Run ./scripts/setup-tile.sh first."; exit 1; }
	@test -f fpga/vendor_refs/icebreaker.pcf || { \
	  echo "vendor pin files missing. Run: python3 tools/import_boards.py fetch"; exit 1; }

jtag:                         ## test access port against a model of IEEE 1149.1
	python3 dbg/tb/jtag_model.py > /dev/null
	sv2v dbg/rtl/hydra_jtag_tap.sv dbg/tb/tb_jtag_tap.sv > /tmp/hydra_jtag.v
	iverilog -g2012 -o /tmp/hydra_jtag /tmp/hydra_jtag.v
	@vvp -n /tmp/hydra_jtag 2>/dev/null | grep -E 'PASS|FAIL'
	cd dbg && sv2v --define=FORMAL -E Assert rtl/hydra_jtag_tap.sv > formal/jtag_tap_sv2v.v
	cd dbg/formal && sby -f jtag_tap.sby prove | tail -1
	cd dbg/formal && sby -f jtag_tap.sby cover | tail -1

jtag-bridge:                  ## the test port's clock crossing into the register map
	sv2v dbg/rtl/hydra_jtag_bridge.sv dbg/tb/tb_jtag_bridge.sv > /tmp/hydra_jbr.v
	iverilog -g2012 -o /tmp/hydra_jbr /tmp/hydra_jbr.v
	@vvp -n /tmp/hydra_jbr 2>/dev/null | grep -E 'PASS|FAIL'
	@python3 dbg/formal/cdc_check.py

xsec:                         ## security instructions: Zknh + Xhydrasec, vectors and proofs
	python3 isa/tb/xsec_model.py > /dev/null
	sv2v isa/rtl/hydra_xsec_unit.sv > /tmp/hydra_xsec.v
	iverilog -g2012 -o /tmp/hydra_xsec /tmp/hydra_xsec.v isa/tb/tb_xsec_unit.sv
	@vvp -n /tmp/hydra_xsec 2>/dev/null | grep -E 'PASS|FAIL'
	cd isa && sv2v --define=FORMAL -E Assert rtl/hydra_xsec_unit.sv \
	  ../sec/rtl/hydra_key_vault.sv formal/xsec_ni.sv > formal/xsec_sv2v.v
	cd isa/formal && sby -f xsec.sby priv | tail -1
	cd isa/formal && sby -f xsec.sby ni | tail -1

sync-tile:                    ## copy the VERIFIED tile into ~/src/tinytapeout-hydra and prove it by hash
	./scripts/sync-tile.sh

# The tile carries its own copy of hydra_rst_sync because the tile repository
# must build on its own. The formally verified original is common/rtl. Two
# copies of one module drift silently, so verification refuses to pass unless
# they are byte-identical. (Session 2026-10-02: adding the copy also broke the
# full-chip build, which named both -- caught by release.sh, not before.)
rst-sync-copy:                ## the tile's reset synchroniser is the verified one, byte for byte
	@cmp -s common/rtl/hydra_rst_sync.sv tt/tile/src/rtl/hydra_rst_sync.sv \
	  && echo "PASS rst-sync-copy: tile copy identical to the verified common/rtl original" \
	  || { echo "FAIL rst-sync-copy: tt/tile/src/rtl/hydra_rst_sync.sv differs from common/rtl"; exit 1; }

tile-gl:                      ## the 17 tile tests on the HARDENED netlist (needs a harden and the PDK)
	./scripts/tile-gl.sh $(or $(RUN),$(HOME)/src/tinytapeout-hydra)

render-layout:                ## render the hardened tile into both READMEs' docs/img/layout.png
	./scripts/render-layout.sh $(or $(RUN),$(HOME)/src/tinytapeout-hydra)

slew-report:                  ## group slew/capacitance warnings by net and name each driver
	python3 tools/slew_report.py $(or $(RUN),$(HOME)/src/tinytapeout-hydra)

critical-paths:               ## classify the failing timing paths of a harden run (run in the hardening checkout)
	python3 tools/critical_paths.py $(or $(RUN),$(HOME)/src/tinytapeout-hydra)

tt-ready:                     ## is the tile ready for the next shuttle? (fast checks)
	python3 tools/tt_ready.py

tt-ready-full:                ## the same, plus synthesis and the tile tests
	python3 tools/tt_ready.py --full

basys3-selftest:              ## Basys 3 bring-up image: banner, hex display, 16 LEDs, 5 buttons
	sv2v fpga/rtl/hydra_fpga_uart.sv fpga/rtl/hydra_fpga_selftest.sv \
	  fpga/rtl/hydra_basys3_selftest.sv > /tmp/hydra_b3.v
	iverilog -g2012 -o /tmp/hydra_b3 /tmp/hydra_b3.v fpga/tb_basys3_selftest.sv
	@vvp -n /tmp/hydra_b3 2>/dev/null | grep -E 'PASS|FAIL'
	@python3 tools/gen_basys3_xdc.py fpga/rtl/hydra_basys3_selftest.sv \
	  fpga/build/basys3-selftest/hydra_basys3_selftest.xdc

basys3-bit:                   ## build the Basys 3 bitstream with Vivado
	vivado -mode batch -nojournal -nolog -source fpga/build/basys3-selftest/build.tcl

flash-basys3:                 ## load the Basys 3 bring-up image (volatile)
	openFPGALoader -b basys3 fpga/build/basys3-selftest/hydra_basys3_selftest.bit

selftest:                     ## board bring-up image: sweep, switches, pattern, serial
	sv2v fpga/rtl/hydra_fpga_uart.sv fpga/rtl/hydra_fpga_selftest.sv > /tmp/hydra_selftest.v
	iverilog -g2012 -o /tmp/hydra_selftest /tmp/hydra_selftest.v fpga/tb_fpga_selftest.sv
	@vvp -n /tmp/hydra_selftest 2>/dev/null | grep -E 'PASS|FAIL'

selftest-bit:                 ## build the bring-up bitstream for the ECP5 evaluation board
	python3 tools/hydra_bind.py build --plan plans/ecp5-evn-selftest.yaml
	$(MAKE) -C fpga/build/ecp5-evn-selftest

flash-selftest:               ## load the bring-up image into the FPGA (volatile)
	# Needs the board attached to WSL first: see docs/FPGA_BRINGUP.md step 3.
	openFPGALoader -b ecp5_evn fpga/build/ecp5-evn-selftest/hydra_ecp5_evn_selftest.bit

pcr:                          ## measurement register: extend-only, chain checked against hashlib
	python3 sec/tb/pcr_model.py > /dev/null
	sv2v sec/rtl/hydra_sha256.sv sec/rtl/hydra_pcr.sv sec/tb/tb_pcr.sv > /tmp/hydra_pcr.v
	iverilog -g2012 -o /tmp/hydra_pcr /tmp/hydra_pcr.v
	@vvp -n /tmp/hydra_pcr 2>/dev/null | grep -E 'PASS|FAIL'
	cd sec && sv2v --define=FORMAL -E Assert rtl/hydra_sha256.sv rtl/hydra_pcr.sv > formal/pcr_sv2v.v
	cd sec/formal && sby -f pcr.sby prove | tail -1

sha256:                       ## hash engine against hashlib, an outside reference
	python3 sec/tb/sha256_model.py > /dev/null
	sv2v sec/rtl/hydra_sha256.sv sec/tb/tb_sha256.sv > /tmp/hydra_sha.v
	iverilog -g2012 -o /tmp/hydra_sha /tmp/hydra_sha.v
	@vvp -n /tmp/hydra_sha 2>/dev/null | grep -E 'PASS|FAIL'

mailbox:                      ## Caliptra-style mailbox: lock discipline and protocol enforcement
	sv2v sec/rtl/hydra_mailbox.sv sec/tb/tb_mailbox.sv > /tmp/hydra_mbox.v
	iverilog -g2012 -o /tmp/hydra_mbox /tmp/hydra_mbox.v
	@vvp -n /tmp/hydra_mbox 2>/dev/null | grep -E 'PASS|FAIL'
	cd sec && sv2v --define=FORMAL -E Assert rtl/hydra_mailbox.sv > formal/mailbox_sv2v.v
	cd sec/formal && sby -f mailbox.sby prove | tail -1
	cd sec/formal && sby -f mailbox.sby cover | tail -1

keyvault:                     ## key vault: invariants, and no key bit reaches the host port
	cd sec && sv2v --define=FORMAL -E Assert rtl/hydra_key_vault.sv \
	  formal/key_vault_ni.sv > formal/key_vault_sv2v.v
	cd sec/formal && sby -f key_vault.sby prove | tail -1
	cd sec/formal && sby -f key_vault.sby ni | tail -1
	cd sec/formal && sby -f key_vault.sby cover | tail -1

padmux:                       ## model comparison + formal proofs
	cd common/tb && python3 padmux_model.py padmux_vectors.hex 20000 1 && \
	  iverilog -g2012 -o /tmp/tb_padmux ../rtl/hydra_padmux.sv tb_hydra_padmux.sv && \
	  vvp -n /tmp/tb_padmux | tail -1
	cd common/formal && sby -f hydra_padmux.sby prove | tail -1 && \
	  sby -f hydra_rst_sync.sby prove | tail -1
	cd tt/formal && sby -f hydra_tt_spi.sby prove | tail -1

tile:                         ## the tile's cocotb suite, both personalities
	# Regenerate to a TEMPORARY file and compare, rather than overwriting
	# project.v and asking git whether it changed. The git form failed for
	# any uncommitted work -- including work that was perfectly consistent --
	# and it passed trivially when the target had just rewritten the file it
	# was about to check. What matters is that the project.v in the tree
	# matches its sources, which is what this compares.
	@cd $(TILE)/src && bash regen.sh > /tmp/tt_project_regen.v
	@diff -q $(TILE)/src/project.v /tmp/tt_project_regen.v > /dev/null || \
	  { echo "project.v differs from its sources -- run: cd $(TILE)/src && ./regen.sh > project.v"; exit 1; }
	cd $(TILE)/test && rm -rf sim_build && $(MAKE) -s 2>&1 | grep -E "TESTS=|FAIL"

bootstrap:                    ## fresh checkout: fetch vendor files, then check the toolchain
	# `make verify` fails on a fresh clone with "vendor pin files missing":
	# the board pin definitions are fetched from their upstream projects
	# rather than copied into this repository, so the provenance check has
	# something to compare against. This does that, then reports what else
	# the machine is missing.
	python3 tools/import_boards.py fetch
	@./scripts/doctor.sh

doctor:                       ## does this machine have the tools? (run from anywhere)
	@./scripts/doctor.sh

release:                      ## verify, then push both repos in the right order (MSG="...")
	@test -n "$(MSG)" || (echo 'release: give a message, e.g. make release MSG="what changed"'; false)
	./scripts/release.sh -m "$(MSG)"

release-dry:                  ## show exactly what release would do
	./scripts/release.sh -m "$(or $(MSG),dry run)" --dry-run

readme-art:                   ## regenerate every README figure from the repository's data
	python3 tools/gen_readme_art.py

site:                         ## regenerate the project page and the architecture diagram
	python3 tools/gen_site.py

site-check:                   ## the page and diagram still match the repository
	@cp docs/site/index.html /tmp/site_was.html
	@cp docs/ARCHITECTURE.md /tmp/arch_was.md
	@python3 tools/gen_site.py > /dev/null
	@diff -q /tmp/site_was.html docs/site/index.html > /dev/null \
	  && diff -q /tmp/arch_was.md docs/ARCHITECTURE.md > /dev/null \
	  && echo "site: page and diagram match the repository" \
	  || (echo "site: OUT OF DATE -- regenerated, commit the result"; false)

cost-mux:                     ## the shared cost engine decides what the parallel one decides
	cd tt && sv2v --define=HYDRA_COST_SHARED="1'b1" tile/src/rtl/*.sv tb/tb_cost_trace.sv \
	  > /tmp/ct_s.v && iverilog -g2012 -o /tmp/ct_s /tmp/ct_s.v && \
	  vvp -n /tmp/ct_s | grep -E '^(D|U|END)' > /tmp/ct_s.txt
	cd tt && sv2v --define=HYDRA_COST_SHARED="1'b0" tile/src/rtl/*.sv tb/tb_cost_trace.sv \
	  > /tmp/ct_p.v && iverilog -g2012 -o /tmp/ct_p /tmp/ct_p.v && \
	  vvp -n /tmp/ct_p | grep -E '^(D|U|END)' > /tmp/ct_p.txt
	@diff -q /tmp/ct_s.txt /tmp/ct_p.txt > /dev/null \
	  && echo "PASS cost-mux: $$(wc -l < /tmp/ct_s.txt) decisions identical to the parallel build" \
	  || (echo "FAIL cost-mux: the two builds disagree"; diff /tmp/ct_s.txt /tmp/ct_p.txt | head; false)

cost-mux-mutate:              ## break the sequencer five ways
	python3 tools/mutate_cost_mux.py

diff:                         ## v2 legacy is v1, pin for pin
	cd tt && sv2v --define=HYDRA_COST_SHARED="1'b0" \
	  tile/src/rtl/*.sv tile/src/tt_um_hydra_mom.sv rtl/tt_um_hydra_mom_v1.sv \
	  > /tmp/hydra_diff.v && \
	  iverilog -g2012 -o /tmp/hydra_diff /tmp/hydra_diff.v tb/tb_v1_v2_diff.sv && \
	  vvp -n /tmp/hydra_diff | tail -2

harness:                      ## the PC protocol, end to end
	cd fpga && sv2v ../tt/tile/src/rtl/*.sv ../tt/tile/src/tt_um_hydra_mom.sv \
	  rtl/hydra_fpga_uart.sv rtl/hydra_fpga_bridge.sv \
	  rtl/hydra_fpga_tt_harness.sv > /tmp/hydra_harness.v && \
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

tpu:                          ## TPU: golden-model comparison and the port proof
	python3 engines/tpu/tb/tpu_model.py 4
	sv2v engines/tpu/rtl/*.sv engines/tpu/tb/tb_tpu.sv > /tmp/hydra_tpu.v
	iverilog -g2012 -o /tmp/hydra_tpu /tmp/hydra_tpu.v
	vvp -n /tmp/hydra_tpu 2>/dev/null | tail -2
	cd engines/tpu && sv2v --define=FORMAL -E Assert rtl/tpu_pkg.sv rtl/tpu_ctrl.sv \
	  > formal/tpu_ctrl_sv2v.v && cd formal && sby -f tpu_ctrl.sby prove | tail -1

tpu-mutate:                   ## break the TPU nine ways; each must be caught
	python3 engines/tpu/formal/mutate_tpu.py

systile:                      ## dispatcher + crossbar + engines over SPI
	sv2v tt/tile/src/rtl/*.sv common/rtl/mom_xbar.sv \
	  sys/rtl/hydra_sys_tile.sv sys/tb/tb_sys_tile.sv > /tmp/hydra_systile.v
	iverilog -g2012 -o /tmp/hydra_systile /tmp/hydra_systile.v
	vvp -n /tmp/hydra_systile | tail -5

simd:                         ## vector unit: model comparison and port proof
	python3 engines/simd/tb/simd_model.py 4
	sv2v engines/simd/rtl/*.sv engines/simd/tb/tb_simd.sv > /tmp/hydra_simd.v
	iverilog -g2012 -o /tmp/hydra_simd /tmp/hydra_simd.v
	vvp -n /tmp/hydra_simd 2>/dev/null | tail -2
	cd engines/simd && sv2v --define=FORMAL -E Assert rtl/simd_pkg.sv rtl/simd_ctrl.sv \
	  > formal/simd_ctrl_sv2v.v && cd formal && sby -f simd_ctrl.sby prove | tail -1

ntt:                          ## butterfly engine: model comparison and proof
	python3 engines/ntt/tb/ntt_model.py 4
	sv2v engines/ntt/rtl/*.sv engines/ntt/tb/tb_ntt.sv > /tmp/hydra_ntt.v
	iverilog -g2012 -o /tmp/hydra_ntt /tmp/hydra_ntt.v
	vvp -n /tmp/hydra_ntt 2>/dev/null | tail -2
	cd engines/ntt && sv2v --define=FORMAL -E Assert rtl/ntt_pkg.sv rtl/ntt_ctrl.sv \
	  > formal/ntt_ctrl_sv2v.v && cd formal && sby -f ntt_ctrl.sby prove | tail -1

dma:                          ## the array fed from real memory, results in memory
	python3 mem/tb/dma_model.py 6
	sv2v engines/tpu/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_tpu_dma.sv \
	  mem/tb/tb_hydra_dma.sv > /tmp/hydra_dma.v
	iverilog -g2012 -o /tmp/hydra_dma /tmp/hydra_dma.v
	vvp -n /tmp/hydra_dma 2>/dev/null | tail -2
	cd mem && sv2v --define=FORMAL -E Assert rtl/hydra_dma_agen.sv rtl/hydra_dma_gemm.sv \
	  > formal/hydra_dma_sv2v.v && cd formal && sby -f hydra_dma_gemm.sby prove | tail -1

dma-simd:                     ## the vector unit fed from memory (it stalls; the array does not)
	python3 mem/tb/dma_simd_model.py 8 > /dev/null
	sv2v engines/simd/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_simd_dma.sv \
	  mem/tb/tb_hydra_dma_simd.sv > /tmp/hydra_dma_simd.v
	iverilog -g2012 -o /tmp/hydra_dma_simd /tmp/hydra_dma_simd.v
	vvp -n /tmp/hydra_dma_simd 2>/dev/null | tail -2

dma-ntt:                      ## the butterfly engine fed from three banks
	python3 mem/tb/dma_ntt_model.py 6 > /dev/null
	sv2v engines/ntt/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_ntt_dma.sv \
	  mem/tb/tb_hydra_dma_ntt.sv > /tmp/hydra_dma_ntt.v
	iverilog -g2012 -o /tmp/hydra_dma_ntt /tmp/hydra_dma_ntt.v
	vvp -n /tmp/hydra_dma_ntt 2>/dev/null | grep -E 'PASS|FAIL'

memboard:                     ## the whole path over the serial port
	python3 mem/tb/dma_model.py 6 > /dev/null
	sv2v tt/tile/src/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv \
	  engines/simd/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_tpu.sv \
	  sys/rtl/hydra_engine_simd.sv sys/rtl/hydra_engine_tpu_dma.sv \
	  sys/rtl/hydra_sys_tile.sv fpga/rtl/hydra_fpga_uart.sv \
	  fpga/rtl/hydra_fpga_bridge.sv fpga/rtl/hydra_fpga_mem_harness.sv \
	  fpga/tb_fpga_mem.sv > /tmp/hydra_memboard.v
	iverilog -g2012 -o /tmp/hydra_memboard /tmp/hydra_memboard.v
	vvp -n /tmp/hydra_memboard 2>/dev/null | tail -2

dma-mutate:                   ## break the memory path nine ways
	python3 mem/formal/mutate_dma.py

ntt-moduli:                   ## the butterfly engine at every standardised modulus
	@for Q in 12289 3329 8380417; do \
	  HYDRA_NTT_Q=$$Q python3 engines/ntt/tb/ntt_model.py 4 > /dev/null; \
	  sv2v --define=HYDRA_NTT_Q=$$Q engines/ntt/rtl/*.sv engines/ntt/tb/tb_ntt.sv \
	    > /tmp/ntt_q$$Q.v; \
	  iverilog -g2012 -o /tmp/ntt_q$$Q /tmp/ntt_q$$Q.v; \
	  printf 'q=%-9s %s\n' "$$Q" "$$(vvp -n /tmp/ntt_q$$Q 2>/dev/null | grep -E 'PASS|FAIL' | head -1)"; \
	done
	@HYDRA_NTT_Q=12289 python3 engines/ntt/tb/ntt_model.py 4 > /dev/null

ntt-mutate:                   ## break the butterfly engine nine ways
	python3 engines/ntt/formal/mutate_ntt.py

simd-mutate:                  ## break the vector unit ten ways
	python3 engines/simd/formal/mutate_simd.py

systile-two:                  ## the dispatcher routing between TWO real engines
	python3 sys/tb/simd_pattern_model.py > /dev/null
	python3 sys/tb/tpu_pattern_model.py 4 > /dev/null
	sv2v tt/tile/src/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv \
	  engines/simd/rtl/*.sv sys/rtl/hydra_engine_tpu.sv sys/rtl/hydra_engine_simd.sv \
	  sys/rtl/hydra_sys_tile.sv sys/tb/tb_sys_tile_two.sv > /tmp/hydra_two.v
	iverilog -g2012 -o /tmp/hydra_two /tmp/hydra_two.v
	vvp -n /tmp/hydra_two 2>/dev/null | tail -3

systile-tpu:                  ## the dispatcher scheduling the REAL array
	python3 sys/tb/tpu_pattern_model.py 4 > /dev/null
	sv2v tt/tile/src/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv \
	  sys/rtl/hydra_engine_tpu.sv sys/rtl/hydra_sys_tile.sv \
	  sys/tb/tb_sys_tile_tpu.sv > /tmp/hydra_systile_tpu.v
	iverilog -g2012 -o /tmp/hydra_systile_tpu /tmp/hydra_systile_tpu.v
	vvp -n /tmp/hydra_systile_tpu 2>/dev/null | tail -4

sky130:                       ## the chip through its pads: pad mux, bring-up, SPI
	sv2v tt/tile/src/rtl/*.sv tt/tile/src/tt_um_hydra_mom.sv \
	  common/rtl/hydra_padmux.sv \
	  sky130/rtl/hydra_openframe_top.sv > /tmp/hydra_of.v
	iverilog -g2012 -o /tmp/hydra_of /tmp/hydra_of.v sky130/tb/tb_openframe.sv
	vvp -n /tmp/hydra_of | tail -2

area:                         ## sky130 cell area of the tile, v1 against v2
	./tools/sky130_area.sh HEAD b179c6b

area-ntt:                     ## sky130 cell area of the butterfly engine, each modulus (slow: desktop)
	./tools/ntt_area.sh

isa:                          ## regenerate every instruction document
	python3 tools/gen_isa_doc.py
	python3 tools/isa/gen_cpu_isa.py
	python3 tools/isa/gen_gpu_isa.py

isa-check:                    ## fail if any instruction document has drifted
	python3 tools/gen_isa_doc.py --check
	python3 tools/isa/gen_cpu_isa.py --check
	python3 tools/isa/gen_gpu_isa.py --check

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

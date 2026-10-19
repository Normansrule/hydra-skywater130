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
# Every simulation goes through runsim.sh: sv2v turns $$fatal into $$finish(1),
# which Icarus exits 0 on, so an exit code alone cannot be trusted (audit R5).
SIM := $(CURDIR)/scripts/runsim.sh
# Every converted netlist and simulator executable lives inside THIS checkout
# (audit R5 follow-up, 2026-10-11). They used to share fixed names in /tmp,
# so two checkouts -- or scripts/ci_selftest.sh's broken copy next to the real
# tree -- could run each other's executables.
SIMTMP := $(CURDIR)/build/sim
$(shell mkdir -p $(SIMTMP))
TILE  := tt/tile

.PHONY: status provenance readme-check sha256-stream measure verify all tt asic fpga padmux tile diff harness sky130 tools boards bind mutate area capacity clean check-tile

status:                       ## what is set up, what is not, what to run next
	@./scripts/status.sh

provenance:                   ## which board bitstreams were built from the current sources
	@for d in fpga/build/*/; do grep -q '^provenance:' $$d/Makefile 2>/dev/null || continue; \
	  $(MAKE) -s --no-print-directory -C $$d provenance 2>/dev/null || true; done

verify: check-deps site-check readme-check tt-ready rst-sync-copy tile-shared lint basys3-selftest check-tile cost-mux cost-cal keyvault mailbox sha256 sha256-stream measure pcr selftest xsec jtag jtag-bridge padmux xbar xbar-bound tpu simd ntt ntt-moduli dma dma-simd dma-ntt memboard system systile systile-tpu systile-mem systile-two tile diff harness jtag-harness gpu systile-gpu select-proof abi-v2 systile-abi cpu-quick systile-cpu sky130 tools boards bind uart-baud isa-check
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
	sv2v dbg/rtl/hydra_jtag_tap.sv dbg/tb/tb_jtag_tap.sv > $(SIMTMP)/hydra_jtag.v
	iverilog -g2012 -o $(SIMTMP)/hydra_jtag $(SIMTMP)/hydra_jtag.v
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_jtag
	cd dbg && sv2v --define=FORMAL -E Assert rtl/hydra_jtag_tap.sv > formal/jtag_tap_sv2v.v
	cd dbg/formal && sby -f jtag_tap.sby prove | tail -1
	cd dbg/formal && sby -f jtag_tap.sby cover | tail -1

jtag-bridge:                  ## the test port's clock crossing into the register map
	sv2v dbg/rtl/hydra_jtag_bridge.sv dbg/tb/tb_jtag_bridge.sv > $(SIMTMP)/hydra_jbr.v
	iverilog -g2012 -o $(SIMTMP)/hydra_jbr $(SIMTMP)/hydra_jbr.v
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_jbr
	@python3 dbg/formal/cdc_check.py

xsec:                         ## security instructions: Zknh + Xhydrasec, vectors and proofs
	python3 isa/tb/xsec_model.py > /dev/null
	sv2v isa/rtl/hydra_xsec_unit.sv > $(SIMTMP)/hydra_xsec.v
	iverilog -g2012 -o $(SIMTMP)/hydra_xsec $(SIMTMP)/hydra_xsec.v isa/tb/tb_xsec_unit.sv
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_xsec
	cd isa && sv2v --define=FORMAL -E Assert rtl/hydra_xsec_unit.sv \
	  ../sec/rtl/hydra_key_vault.sv formal/xsec_ni.sv > formal/xsec_sv2v.v
	cd isa/formal && sby -f xsec.sby priv | tail -1
	cd isa/formal && sby -f xsec.sby ni | tail -1
	cd isa/formal && sby -f xsec.sby ni_full | tail -1

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

# The chip's dispatcher (mom/) and the research tile (tt/tile) are separate
# designs since 2026-10-09: the tile dropped the serial pins, half the tags and
# the descriptor readback. The cost model, scoreboard and calibration are still
# the SAME modules, and every chip-side check (system, systile, cost-mux, the
# SPI proof) verifies them only for the tile if the copies have not drifted.
# hydra_tt_regs.sv is the one module that differs, on purpose.
TILE_SHARED := hydra_tt_spi mom_pkg mom_features mom_param_rom mom_cost_engine \
               mom_calibrate mom_select mom_scoreboard mom_top
tile-shared:                  ## the tile's dispatcher modules are the chip's, byte for byte
	@bad=0; for m in $(TILE_SHARED); do \
	  cmp -s mom/rtl/$$m.sv tt/tile/src/rtl/$$m.sv || { echo "FAIL tile-shared: $$m.sv differs between mom/rtl and tt/tile/src/rtl"; bad=1; }; \
	done; [ $$bad = 0 ] && echo "PASS tile-shared: $(words $(TILE_SHARED)) dispatcher modules identical in chip and tile"

tile-gl:                      ## the tile tests on the HARDENED netlist (needs a harden and the PDK)
	./scripts/tile-gl.sh $(or $(RUN),$(HOME)/src/tinytapeout-hydra)

render-layout:                ## render the hardened tile into both READMEs' docs/img/layout.png
	./scripts/render-layout.sh $(or $(RUN),$(HOME)/src/tinytapeout-hydra)
	@mkdir -p docs/site/media && cp docs/img/layout.png docs/site/media/layout.png

slew-report:                  ## group slew/capacitance warnings by net and name each driver
	python3 tools/slew_report.py $(or $(RUN),$(HOME)/src/tinytapeout-hydra)

harden:                       ## harden the tile unattended: tries each configuration, stops a stalled one
	python3 tools/harden_ladder.py $(or $(RUN),$(HOME)/src/tinytapeout-hydra) $(ARGS)

drt-progress:                 ## is a harden's detailed routing converging? (safe while it runs)
	python3 tools/drt_progress.py $(or $(RUN),$(HOME)/src/tinytapeout-hydra)

critical-paths:               ## classify the failing timing paths of a harden run (run in the hardening checkout)
	python3 tools/critical_paths.py $(or $(RUN),$(HOME)/src/tinytapeout-hydra)

tt-ready:                     ## is the tile ready for the next shuttle? (fast checks)
	python3 tools/tt_ready.py

tt-ready-full:                ## the same, plus synthesis and the tile tests
	python3 tools/tt_ready.py --full

basys3-selftest:              ## Basys 3 bring-up image: banner, hex display, 16 LEDs, 5 buttons
	sv2v fpga/rtl/hydra_fpga_uart.sv fpga/rtl/hydra_fpga_selftest.sv \
	  fpga/rtl/hydra_basys3_selftest.sv > $(SIMTMP)/hydra_b3.v
	iverilog -g2012 -o $(SIMTMP)/hydra_b3 $(SIMTMP)/hydra_b3.v fpga/tb_basys3_selftest.sv
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_b3
	@python3 tools/gen_basys3_xdc.py fpga/rtl/hydra_basys3_selftest.sv \
	  fpga/build/basys3-selftest/hydra_basys3_selftest.xdc

basys3-bit:                   ## build the Basys 3 bitstream with Vivado
	vivado -mode batch -nojournal -nolog -source fpga/build/basys3-selftest/build.tcl

flash-basys3:                 ## load the Basys 3 bring-up image (volatile)
	openFPGALoader -b basys3 fpga/build/basys3-selftest/hydra_basys3_selftest.bit

selftest:                     ## board bring-up image: sweep, switches, pattern, serial
	sv2v fpga/rtl/hydra_fpga_uart.sv fpga/rtl/hydra_fpga_selftest.sv > $(SIMTMP)/hydra_selftest.v
	iverilog -g2012 -o $(SIMTMP)/hydra_selftest $(SIMTMP)/hydra_selftest.v fpga/tb_fpga_selftest.sv
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_selftest

selftest-bit:                 ## build the bring-up bitstream for the ECP5 evaluation board
	python3 tools/hydra_bind.py build --plan plans/ecp5-evn-selftest.yaml
	$(MAKE) -C fpga/build/ecp5-evn-selftest

flash-selftest:               ## load the bring-up image into the FPGA (volatile)
	# Needs the board attached to WSL first: see docs/FPGA_BRINGUP.md step 3.
	openFPGALoader -b ecp5_evn fpga/build/ecp5-evn-selftest/hydra_ecp5_evn_selftest.bit

pcr:                          ## measurement register: extend-only, chain checked against hashlib
	python3 sec/tb/pcr_model.py > /dev/null
	sv2v sec/rtl/hydra_sha256.sv sec/rtl/hydra_pcr.sv sec/tb/tb_pcr.sv > $(SIMTMP)/hydra_pcr.v
	iverilog -g2012 -o $(SIMTMP)/hydra_pcr $(SIMTMP)/hydra_pcr.v
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_pcr
	cd sec && sv2v --define=FORMAL -E Assert rtl/hydra_sha256.sv rtl/hydra_pcr.sv > formal/pcr_sv2v.v
	cd sec/formal && sby -f pcr.sby prove | tail -1

sha256:                       ## hash engine against hashlib, an outside reference
	python3 sec/tb/sha256_model.py > /dev/null
	sv2v sec/rtl/hydra_sha256.sv sec/tb/tb_sha256.sv > $(SIMTMP)/hydra_sha.v
	iverilog -g2012 -o $(SIMTMP)/hydra_sha $(SIMTMP)/hydra_sha.v
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_sha

sha256-stream:                ## SHA-256 padded in hardware: 140 lengths vs hashlib, padding proved
	python3 sec/tb/sha256_stream_model.py > /dev/null
	sv2v sec/rtl/hydra_sha256.sv sec/rtl/hydra_sha256_stream.sv sec/tb/tb_sha256_stream.sv > $(SIMTMP)/hydra_sha_stream.v
	iverilog -g2012 -o $(SIMTMP)/hydra_sha_stream $(SIMTMP)/hydra_sha_stream.v
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_sha_stream
	cd sec && sv2v --define=FORMAL -E Assert rtl/hydra_sha256_stream.sv > formal/sha256_stream_sv2v.v
	cd sec/formal && sby -f sha256_stream.sby prove | tail -1
	cd sec/formal && sby -f sha256_stream.sby blocks | tail -1
	cd sec/formal && sby -f sha256_stream.sby cover | tail -1

measure:                      ## image bytes -> SHA-256 -> PCR on one core: vs hashlib, plus proof
	python3 sec/tb/measure_model.py > /dev/null
	sv2v sec/rtl/hydra_sha256.sv sec/rtl/hydra_sha256_stream.sv \
	  sec/rtl/hydra_measure.sv sec/tb/tb_measure.sv > $(SIMTMP)/hydra_measure.v
	iverilog -g2012 -o $(SIMTMP)/hydra_measure $(SIMTMP)/hydra_measure.v
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_measure
	cd sec && sv2v --define=FORMAL -E Assert rtl/hydra_sha256_stream.sv rtl/hydra_measure.sv > formal/measure_sv2v.v
	cd sec/formal && sby -f measure.sby prove | tail -1
	cd sec/formal && sby -f measure.sby cover | tail -1

mailbox:                      ## Caliptra-style mailbox: lock discipline and protocol enforcement
	sv2v sec/rtl/hydra_mailbox.sv sec/tb/tb_mailbox.sv > $(SIMTMP)/hydra_mbox.v
	iverilog -g2012 -o $(SIMTMP)/hydra_mbox $(SIMTMP)/hydra_mbox.v
	@$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_mbox
	cd sec && sv2v --define=FORMAL -E Assert rtl/hydra_mailbox.sv > formal/mailbox_sv2v.v
	cd sec/formal && sby -f mailbox.sby prove | tail -1
	cd sec/formal && sby -f mailbox.sby cover | tail -1

keyvault:                     ## key vault: invariants, and no key bit reaches the host port
	cd sec && sv2v --define=FORMAL -E Assert rtl/hydra_key_vault.sv \
	  formal/key_vault_ni.sv > formal/key_vault_sv2v.v
	cd sec/formal && sby -f key_vault.sby prove | tail -1
	cd sec/formal && sby -f key_vault.sby ni | tail -1
	cd sec/formal && sby -f key_vault.sby ni_full | tail -1
	cd sec/formal && sby -f key_vault.sby cover | tail -1

padmux:                       ## model comparison + formal proofs
	cd common/tb && python3 padmux_model.py padmux_vectors.hex 20000 1 && \
	  iverilog -g2012 -o $(SIMTMP)/tb_padmux ../rtl/hydra_padmux.sv tb_hydra_padmux.sv && \
	  $(SIM) --tail 1 -- vvp -n $(SIMTMP)/tb_padmux
	cd common/formal && sby -f hydra_padmux.sby prove | tail -1 && \
	  sby -f hydra_rst_sync.sby prove | tail -1
	cd tt/formal && sby -f hydra_tt_spi.sby prove | tail -1

tile:                         ## the research tile's cocotb suite (22 tests, register map)
	# Regenerate to a TEMPORARY file and compare, rather than overwriting
	# project.v and asking git whether it changed. The git form failed for
	# any uncommitted work -- including work that was perfectly consistent --
	# and it passed trivially when the target had just rewritten the file it
	# was about to check. What matters is that the project.v in the tree
	# matches its sources, which is what this compares.
	@cd $(TILE)/src && bash regen.sh > $(SIMTMP)/tt_project_regen.v
	@diff -q $(TILE)/src/project.v $(SIMTMP)/tt_project_regen.v > /dev/null || \
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
	python3 tools/gen_readme_hero.py
	python3 tools/gen_readme_visuals.py
	python3 tools/gen_readme_gifs.py

readme-check:                 ## lead figures current; README numbers match the latest harden
	@python3 tools/gen_readme_hero.py --check
	@python3 tools/gen_readme_visuals.py --check
	@python3 tools/gen_readme_gifs.py --check

site:                         ## regenerate the project page and the architecture diagram
	python3 tools/gen_site.py

site-check:                   ## the page and diagram still match the repository (writes nothing)
	@python3 tools/gen_site.py --check

atlas:                        ## the atlas data: what each build elaborates, every trace re-recorded from passing tests
	python3 tools/atlas_derive.py
	python3 tools/atlas_traces.py
	python3 tools/gen_site.py

atlas-physical:               ## map a hardened run's placed cells to RTL instances (RUN= run dir, LADDER= its id)
	python3 tools/atlas_physical.py $(or $(RUN),$(HOME)/src/tinytapeout-hydra/runs/wokwi) $(if $(LADDER),--ladder $(LADDER)) $(if $(NOTE),--note "$(NOTE)")
	python3 tools/gen_site.py

atlas-flow:                   ## one harden run, step by step, from its own logs (RUN= run dir, LABEL= what it is)
	python3 tools/atlas_flow.py $(or $(RUN),$(HOME)/src/tinytapeout-hydra/runs/wokwi) --label "$(or $(LABEL),the last harden)"
	python3 tools/gen_site.py

cost-cal:                     ## cost and calibration arithmetic against exact products (MODEL-01/02)
	sv2v mom/rtl/mom_pkg.sv mom/rtl/mom_cost_engine.sv mom/rtl/mom_calibrate.sv \
	  tt/tb/tb_cost_cal.sv > $(SIMTMP)/hydra_cost_cal.v
	iverilog -g2012 -o $(SIMTMP)/hydra_cost_cal $(SIMTMP)/hydra_cost_cal.v
	$(SIM) --show '^(PASS|FAIL|MODEL)' -- vvp -n $(SIMTMP)/hydra_cost_cal

cost-mux:                     ## the shared cost engine decides what the parallel one decides
	cd tt && sv2v --define=HYDRA_COST_SHARED="1'b1" ../mom/rtl/*.sv tb/tb_cost_trace.sv \
	  > $(SIMTMP)/ct_s.v && iverilog -g2012 -o $(SIMTMP)/ct_s $(SIMTMP)/ct_s.v && \
	  $(SIM) --expect '^END' --tail 0 -- vvp -n $(SIMTMP)/ct_s && vvp -n $(SIMTMP)/ct_s | grep -E '^(D|U|END)' > $(SIMTMP)/ct_s.txt
	cd tt && sv2v --define=HYDRA_COST_SHARED="1'b0" ../mom/rtl/*.sv tb/tb_cost_trace.sv \
	  > $(SIMTMP)/ct_p.v && iverilog -g2012 -o $(SIMTMP)/ct_p $(SIMTMP)/ct_p.v && \
	  $(SIM) --expect '^END' --tail 0 -- vvp -n $(SIMTMP)/ct_p && vvp -n $(SIMTMP)/ct_p | grep -E '^(D|U|END)' > $(SIMTMP)/ct_p.txt
	@diff -q $(SIMTMP)/ct_s.txt $(SIMTMP)/ct_p.txt > /dev/null \
	  && echo "PASS cost-mux: $$(wc -l < $(SIMTMP)/ct_s.txt) decisions identical to the parallel build" \
	  || (echo "FAIL cost-mux: the two builds disagree"; diff $(SIMTMP)/ct_s.txt $(SIMTMP)/ct_p.txt | head; false)

abi-v2:                       ## descriptor ABI version 2: refusals and eligibility against an independent model, plus proofs
	python3 sys/tb/abi_v2_model.py $(SIMTMP)/abi_v2_vectors.txt 4000
	sv2v mom/rtl/mom_pkg.sv sys/rtl/hydra_abi_v2.sv sys/tb/tb_abi_v2.sv > $(SIMTMP)/hydra_abi_v2.v
	iverilog -g2012 -o $(SIMTMP)/hydra_abi_v2 $(SIMTMP)/hydra_abi_v2.v
	$(SIM) --tail 1 -- vvp -n $(SIMTMP)/hydra_abi_v2 +vec=$(SIMTMP)/abi_v2_vectors.txt
	cd sys && sv2v --define=FORMAL -E Assert ../mom/rtl/mom_pkg.sv rtl/hydra_abi_v2.sv > formal/hydra_abi_v2_sv2v.v
	cd sys/formal && sby -f hydra_abi_v2.sby | tail -1

select-proof:                 ## the engine selector is valid, minimal and tie-breaks low, at 5 and 6 slots
	cd mom && sv2v --define=FORMAL -E Assert rtl/mom_pkg.sv rtl/mom_select.sv > formal/mom_select_sv2v.v
	cd mom/formal && sby -f mom_select.sby n5 | tail -1
	cd mom/formal && sby -f mom_select.sby n6 | tail -1

mom-mutate:                   ## put each SkyWater 130 audit fix in the dispatcher back; its test must fail
	python3 tools/mutate_mom.py

cost-mux-mutate:              ## break the sequencer five ways
	python3 tools/mutate_cost_mux.py

diff:                         ## v2 legacy is v1, pin for pin
	cd tt && sv2v --define=HYDRA_COST_SHARED="1'b0" \
	  ../mom/rtl/*.sv ../mom/hydra_mom_pins.sv ../common/rtl/hydra_rst_sync.sv rtl/tt_um_hydra_mom_v1.sv \
	  > $(SIMTMP)/hydra_diff.v && \
	  iverilog -g2012 -o $(SIMTMP)/hydra_diff $(SIMTMP)/hydra_diff.v tb/tb_v1_v2_diff.sv && \
	  $(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_diff

SIXFOLD := ext/sixfold-cpu
SIXFOLD_RTL = $(filter-out %Riscv64_top.sv %Scratchpad_Memory.sv %Instruction_Cache.sv %Data_Cache.sv, \
                $(addprefix $(SIXFOLD)/,$(shell cat $(SIXFOLD)/src/sources.f 2>/dev/null)))
cpu-quick:                    ## the CPU wrapper on one program plus every refusal (what the mutation suite runs)
	@test -f $(SIXFOLD)/src/Riscv64.sv || { echo "FAIL cpu-quick: $(SIXFOLD) missing"; exit 1; }
	rm -rf $(SIMTMP)/cpuvec_q && node tools/cpu_vectors.mjs $(SIXFOLD) $(SIMTMP)/cpuvec_q > /dev/null
	iverilog -g2012 -o $(SIMTMP)/hydra_cpu_q $(SIXFOLD_RTL) sys/rtl/hydra_engine_cpu.sv sys/tb/tb_hydra_engine_cpu.sv 2>&1 | \
	  { grep -v -e 'sorry: constant selects' || true; }
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_cpu_q +dir=$(SIMTMP)/cpuvec_q/05_fibonacci +neg

SIXFOLD_CACHED_RTL = $(filter-out %Riscv64_top.sv %Scratchpad_Memory.sv, \
                       $(addprefix $(SIXFOLD)/,$(shell cat $(SIXFOLD)/src/sources.f 2>/dev/null))) \
                     $(SIXFOLD)/fpga/rtl/Main_Memory.sv
cpu-cached:                   ## the synthesizable CPU build (Sixfold's caches + block memory): every program vs the model with caches
	@test -f $(SIXFOLD)/src/Riscv64.sv || { echo "FAIL cpu-cached: $(SIXFOLD) missing"; exit 1; }
	rm -rf $(SIMTMP)/cpuvec_c && node tools/cpu_vectors.mjs $(SIXFOLD) $(SIMTMP)/cpuvec_c > /dev/null
	iverilog -g2012 -Ptb_hydra_engine_cpu.CACHED=1 -o $(SIMTMP)/hydra_cpu_c $(SIXFOLD_CACHED_RTL) \
	  sys/rtl/hydra_engine_cpu.sv sys/tb/tb_hydra_engine_cpu.sv 2>&1 | { grep -v -e 'sorry: constant selects' || true; }
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_cpu_c +dir=$(SIMTMP)/cpuvec_c/05_fibonacci +neg
	@n=0; while read -r p; do \
	  $(SIM) --tail 1 --show '^PASS' -- vvp -n $(SIMTMP)/hydra_cpu_c +dir=$(SIMTMP)/cpuvec_c/$$p || exit 1; \
	  n=$$((n+1)); done < $(SIMTMP)/cpuvec_c/programs.txt; \
	  echo "PASS cpu-cached: $$n Sixfold programs on its caches and block memory give the cached model's registers, TOHOST and cycle count"

cpu-synth:                    ## synthesize the cached CPU build for ECP5 (yosys); prints the resource count
	@mkdir -p build/cpu_synth
	sv2v $(SIXFOLD_CACHED_RTL) sys/rtl/hydra_engine_cpu.sv > build/cpu_synth/cpu.v
	yosys -q -l build/cpu_synth/yosys.log -p "read_verilog build/cpu_synth/cpu.v; chparam -set CACHED 1 hydra_engine_cpu; \
	  synth_ecp5 -top hydra_engine_cpu; tee -q -o build/cpu_synth/stat.txt stat"
	@grep -E 'LUT4|TRELLIS_FF|DP16KD|TRELLIS_DPR16X4' build/cpu_synth/stat.txt && echo "PASS cpu-synth: the cached CPU maps to ECP5 cells"

cpu:                          ## the Sixfold CPU in its HYDRA wrapper: every program vs Sixfold's own model, cycle for cycle
	@test -f $(SIXFOLD)/src/Riscv64.sv || { echo "FAIL cpu: $(SIXFOLD) missing -- git submodule update --init"; exit 1; }
	rm -rf $(SIMTMP)/cpuvec && node tools/cpu_vectors.mjs $(SIXFOLD) $(SIMTMP)/cpuvec > $(SIMTMP)/cpuvec.log
	iverilog -g2012 -o $(SIMTMP)/hydra_cpu $(SIXFOLD_RTL) sys/rtl/hydra_engine_cpu.sv sys/tb/tb_hydra_engine_cpu.sv 2>&1 | \
	  { grep -v -e 'sorry: constant selects' || true; }
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_cpu +dir=$(SIMTMP)/cpuvec/05_fibonacci +neg
	@n=0; while read -r p; do \
	  $(SIM) --tail 1 --show '^PASS' -- vvp -n $(SIMTMP)/hydra_cpu +dir=$(SIMTMP)/cpuvec/$$p || exit 1; \
	  n=$$((n+1)); done < $(SIMTMP)/cpuvec/programs.txt; \
	  echo "PASS cpu: $$n Sixfold programs give the model's registers, TOHOST and cycle count; refusals, limit and ownership checked"

systile-cpu:                  ## CPU, GPU and TPU slots on one chip: a real Sixfold program scheduled to the CPU through ABI v2
	@test -f $(SIXFOLD)/src/Riscv64.sv || { echo "FAIL systile-cpu: $(SIXFOLD) missing"; exit 1; }
	@test -f $(PIXELSTORM)/rtl/ps_gpu_top.v || { echo "FAIL systile-cpu: $(PIXELSTORM) missing"; exit 1; }
	rm -rf $(SIMTMP)/cpuvec_sys && node tools/cpu_vectors.mjs $(SIXFOLD) $(SIMTMP)/cpuvec_sys > /dev/null
	sv2v mom/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv mem/rtl/*.sv \
	  sys/rtl/hydra_engine_tpu_dma.sv sys/rtl/hydra_engine_gpu.sv sys/rtl/hydra_engine_cpu.sv \
	  sys/rtl/hydra_abi_v2.sv sys/rtl/hydra_sys_tile.sv sys/tb/tb_sys_tile_cpu.sv > $(SIMTMP)/hydra_systile_cpu.v
	iverilog -g2012 -I $(PIXELSTORM)/rtl -o $(SIMTMP)/hydra_systile_cpu $(SIMTMP)/hydra_systile_cpu.v \
	  $(PIXELSTORM)/rtl/ps_*.v $(SIXFOLD_RTL) 2>&1 | { grep -v -e 'sorry: constant selects' -e 'verinum' || true; }
	$(SIM) --show '^(PASS|FAIL|[0-9] )' -- vvp -n $(SIMTMP)/hydra_systile_cpu +dir=$(SIMTMP)/cpuvec_sys/05_fibonacci

harness:                      ## the PC protocol, end to end
	cd fpga && sv2v ../mom/rtl/*.sv ../mom/hydra_mom_pins.sv ../common/rtl/hydra_rst_sync.sv \
	  rtl/hydra_fpga_uart.sv rtl/hydra_fpga_bridge.sv \
	  rtl/hydra_fpga_tt_harness.sv > $(SIMTMP)/hydra_harness.v && \
	  iverilog -g2012 -o $(SIMTMP)/hydra_harness $(SIMTMP)/hydra_harness.v tb_fpga_harness.sv && \
	  $(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_harness

jtag-harness:                 ## two host paths (UART and JTAG) into one tile, each alone and together
	cd fpga && sv2v ../mom/rtl/*.sv ../mom/hydra_mom_pins.sv ../common/rtl/hydra_rst_sync.sv \
	  ../dbg/rtl/hydra_jtag_tap.sv ../dbg/rtl/hydra_jtag_bridge.sv \
	  rtl/hydra_fpga_uart.sv rtl/hydra_fpga_bridge.sv rtl/hydra_fpga_jtag_host.sv \
	  rtl/hydra_fpga_tt_jtag_harness.sv > $(SIMTMP)/hydra_jharness.v && \
	  iverilog -g2012 -o $(SIMTMP)/hydra_jharness $(SIMTMP)/hydra_jharness.v tb_fpga_jtag_harness.sv && \
	  $(SIM) --tail 4 -- vvp -n $(SIMTMP)/hydra_jharness

PIXELSTORM := ext/pixelstorm-gpu
gpu:                          ## the Pixelstorm GPU over a HYDRA bank: real kernels vs Pixelstorm's own model
	@test -f $(PIXELSTORM)/rtl/ps_gpu_top.v || { echo "FAIL gpu: $(PIXELSTORM) missing -- git submodule update --init"; exit 1; }
	rm -rf $(SIMTMP)/gpuvec
	node tools/gpu_vectors.js $(PIXELSTORM) $(SIMTMP)/gpuvec 4096 sys/tb/gpu_kernels
	sv2v sys/rtl/hydra_engine_gpu.sv mem/rtl/hydra_spram.sv > $(SIMTMP)/hydra_gpu.v
	iverilog -g2012 -I $(PIXELSTORM)/rtl -o $(SIMTMP)/hydra_gpu $(SIMTMP)/hydra_gpu.v \
	  $(PIXELSTORM)/rtl/ps_*.v sys/tb/tb_hydra_engine_gpu.sv
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_gpu +dir=$(SIMTMP)/gpuvec/01_vector_add +neg
	@n=0; while read -r k; do \
	  $(SIM) --tail 1 --show '^PASS' -- vvp -n $(SIMTMP)/hydra_gpu +dir=$(SIMTMP)/gpuvec/$$k || exit 1; \
	  n=$$((n+1)); done < $(SIMTMP)/gpuvec/kernels.txt; \
	  echo "PASS gpu: $$n kernels match Pixelstorm's model over a HYDRA bank; refusals, ownership and range checked"

xbar:                         ## the engine crossbar against its model and proofs
	cd common/tb && python3 xbar_model.py xbar_vectors.hex 20000 179 && \
	  iverilog -g2012 -o $(SIMTMP)/hydra_xbar ../rtl/mom_xbar.sv tb_mom_xbar.sv && \
	  $(SIM) --tail 1 -- vvp -n $(SIMTMP)/hydra_xbar
	cd common/formal && sby -f mom_xbar.sby prove | tail -1

xbar-bound:                   ## the crossbar at NENG = 1, 5, 7 and 8 (RTL-08)
	iverilog -g2012 -o $(SIMTMP)/hydra_xbar_bound common/rtl/mom_xbar.sv common/tb/tb_mom_xbar_bound.sv
	$(SIM) --show '^(PASS|FAIL)' -- vvp -n $(SIMTMP)/hydra_xbar_bound

system:                       ## the dispatcher, the crossbar and five engines
	sv2v mom/rtl/mom_pkg.sv mom/rtl/mom_features.sv \
	  mom/rtl/mom_param_rom.sv mom/rtl/mom_cost_engine.sv \
	  mom/rtl/mom_calibrate.sv mom/rtl/mom_select.sv \
	  mom/rtl/mom_scoreboard.sv mom/rtl/mom_top.sv \
	  common/rtl/mom_xbar.sv tt/tb/tb_mom_system.sv > $(SIMTMP)/hydra_sys.v
	iverilog -g2012 -o $(SIMTMP)/hydra_sys $(SIMTMP)/hydra_sys.v
	$(SIM) --tail 4 -- vvp -n $(SIMTMP)/hydra_sys

tpu:                          ## TPU: golden-model comparison and the port proof
	python3 engines/tpu/tb/tpu_model.py 4
	sv2v engines/tpu/rtl/*.sv engines/tpu/tb/tb_tpu.sv > $(SIMTMP)/hydra_tpu.v
	iverilog -g2012 -o $(SIMTMP)/hydra_tpu $(SIMTMP)/hydra_tpu.v
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_tpu
	cd engines/tpu && sv2v --define=FORMAL -E Assert rtl/tpu_pkg.sv rtl/tpu_ctrl.sv \
	  > formal/tpu_ctrl_sv2v.v && cd formal && sby -f tpu_ctrl.sby prove | tail -1

tpu-mutate:                   ## break the TPU nine ways; each must be caught
	python3 engines/tpu/formal/mutate_tpu.py

systile:                      ## dispatcher + crossbar + engines over SPI
	sv2v mom/rtl/*.sv common/rtl/mom_xbar.sv \
	  sys/rtl/hydra_sys_tile.sv sys/tb/tb_sys_tile.sv > $(SIMTMP)/hydra_systile.v
	iverilog -g2012 -o $(SIMTMP)/hydra_systile $(SIMTMP)/hydra_systile.v
	$(SIM) --tail 5 -- vvp -n $(SIMTMP)/hydra_systile

simd:                         ## vector unit: model comparison and port proof
	python3 engines/simd/tb/simd_model.py 4
	sv2v engines/simd/rtl/*.sv engines/simd/tb/tb_simd.sv > $(SIMTMP)/hydra_simd.v
	iverilog -g2012 -o $(SIMTMP)/hydra_simd $(SIMTMP)/hydra_simd.v
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_simd
	cd engines/simd && sv2v --define=FORMAL -E Assert rtl/simd_pkg.sv rtl/simd_ctrl.sv \
	  > formal/simd_ctrl_sv2v.v && cd formal && sby -f simd_ctrl.sby prove | tail -1

ntt:                          ## butterfly engine: model comparison and proof
	python3 engines/ntt/tb/ntt_model.py 4
	sv2v engines/ntt/rtl/*.sv engines/ntt/tb/tb_ntt.sv > $(SIMTMP)/hydra_ntt.v
	iverilog -g2012 -o $(SIMTMP)/hydra_ntt $(SIMTMP)/hydra_ntt.v
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_ntt
	cd engines/ntt && sv2v --define=FORMAL -E Assert rtl/ntt_pkg.sv rtl/ntt_ctrl.sv \
	  > formal/ntt_ctrl_sv2v.v && cd formal && sby -f ntt_ctrl.sby prove | tail -1

dma:                          ## the array fed from real memory, results in memory
	python3 mem/tb/dma_model.py 6
	sv2v engines/tpu/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_tpu_dma.sv \
	  mem/tb/tb_hydra_dma.sv > $(SIMTMP)/hydra_dma.v
	iverilog -g2012 -o $(SIMTMP)/hydra_dma $(SIMTMP)/hydra_dma.v
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_dma
	cd mem && sv2v --define=FORMAL -E Assert rtl/hydra_dma_agen.sv rtl/hydra_dma_gemm.sv \
	  > formal/hydra_dma_sv2v.v && cd formal && sby -f hydra_dma_gemm.sby prove | tail -1

dma-simd:                     ## the vector unit fed from memory (it stalls; the array does not)
	python3 mem/tb/dma_simd_model.py 8 > /dev/null
	sv2v engines/simd/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_simd_dma.sv \
	  mem/tb/tb_hydra_dma_simd.sv > $(SIMTMP)/hydra_dma_simd.v
	iverilog -g2012 -o $(SIMTMP)/hydra_dma_simd $(SIMTMP)/hydra_dma_simd.v
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_dma_simd

dma-ntt:                      ## the butterfly engine fed from three banks
	python3 mem/tb/dma_ntt_model.py > /dev/null
	sv2v engines/ntt/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_ntt_dma.sv \
	  mem/tb/tb_hydra_dma_ntt.sv > $(SIMTMP)/hydra_dma_ntt.v
	iverilog -g2012 -o $(SIMTMP)/hydra_dma_ntt $(SIMTMP)/hydra_dma_ntt.v
	$(SIM) --show 'PASS|FAIL' -- vvp -n $(SIMTMP)/hydra_dma_ntt

memboard:                     ## the whole path over the serial port
	python3 mem/tb/dma_model.py 6 > /dev/null
	sv2v mom/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv \
	  engines/simd/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_tpu.sv \
	  sys/rtl/hydra_engine_simd.sv sys/rtl/hydra_engine_tpu_dma.sv \
	  sys/rtl/hydra_sys_tile.sv fpga/rtl/hydra_fpga_uart.sv \
	  fpga/rtl/hydra_fpga_bridge.sv fpga/rtl/hydra_fpga_mem_harness.sv \
	  fpga/tb_fpga_mem.sv > $(SIMTMP)/hydra_memboard.v
	iverilog -g2012 -o $(SIMTMP)/hydra_memboard $(SIMTMP)/hydra_memboard.v
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_memboard

dma-mutate:                   ## break the memory path 26 ways, each audit fix among them
	python3 mem/formal/mutate_dma.py

ntt-moduli:                   ## the butterfly engine at every standardised modulus, alone and through memory
	./scripts/ntt_moduli.sh

ntt-mutate:                   ## break the butterfly engine nine ways
	python3 engines/ntt/formal/mutate_ntt.py

simd-mutate:                  ## break the vector unit ten ways
	python3 engines/simd/formal/mutate_simd.py

systile-two:                  ## the dispatcher routing between TWO real engines
	python3 sys/tb/simd_pattern_model.py > /dev/null
	python3 sys/tb/tpu_pattern_model.py 4 > /dev/null
	sv2v mom/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv \
	  engines/simd/rtl/*.sv sys/rtl/hydra_engine_tpu.sv sys/rtl/hydra_engine_simd.sv \
	  sys/rtl/hydra_sys_tile.sv sys/tb/tb_sys_tile_two.sv > $(SIMTMP)/hydra_two.v
	iverilog -g2012 -o $(SIMTMP)/hydra_two $(SIMTMP)/hydra_two.v
	$(SIM) --tail 3 -- vvp -n $(SIMTMP)/hydra_two

uart-baud:                    ## every board image's serial port against an independently timed host, +-2% (audit R4)
	./scripts/uart_baud.sh

ci-selftest:                  ## break the design one stage at a time; every break must fail its target
	./scripts/ci_selftest.sh

systile-mem:                  ## the dispatcher and the memory-fed array, two jobs back to back (audit R1)
	sv2v mom/rtl/*.sv common/rtl/hydra_rst_sync.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv \
	  engines/simd/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_tpu.sv sys/rtl/hydra_engine_simd.sv \
	  sys/rtl/hydra_engine_tpu_dma.sv sys/rtl/hydra_sys_tile.sv sys/tb/tb_sys_tile_mem.sv > $(SIMTMP)/hydra_systile_mem.v
	iverilog -g2012 -o $(SIMTMP)/hydra_systile_mem $(SIMTMP)/hydra_systile_mem.v
	$(SIM) --show '^(PASS|FAIL|job)' -- vvp -n $(SIMTMP)/hydra_systile_mem

systile-gpu:                  ## six slots: the scheduler sends INT32 GEMM to the GPU, INT8 to the array
	@test -f $(PIXELSTORM)/rtl/ps_gpu_top.v || { echo "FAIL systile-gpu: $(PIXELSTORM) missing"; exit 1; }
	rm -rf $(SIMTMP)/gpuvec_sys && node tools/gpu_vectors.js $(PIXELSTORM) $(SIMTMP)/gpuvec_sys 4096 > /dev/null
	sv2v mom/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv mem/rtl/*.sv \
	  sys/rtl/hydra_engine_tpu_dma.sv sys/rtl/hydra_engine_gpu.sv sys/rtl/hydra_sys_tile.sv \
	  sys/tb/tb_sys_tile_gpu.sv > $(SIMTMP)/hydra_systile_gpu.v
	iverilog -g2012 -I $(PIXELSTORM)/rtl -o $(SIMTMP)/hydra_systile_gpu $(SIMTMP)/hydra_systile_gpu.v $(PIXELSTORM)/rtl/ps_*.v
	$(SIM) --show '^(PASS|FAIL|GPU)' -- vvp -n $(SIMTMP)/hydra_systile_gpu +dir=$(SIMTMP)/gpuvec_sys/07_matmul

systile-abi:                  ## ABI version 2 end to end: contexts, modes, forced engines, no fallback
	@test -f $(PIXELSTORM)/rtl/ps_gpu_top.v || { echo "FAIL systile-abi: $(PIXELSTORM) missing"; exit 1; }
	rm -rf $(SIMTMP)/gpuvec_abi && node tools/gpu_vectors.js $(PIXELSTORM) $(SIMTMP)/gpuvec_abi 4096 > /dev/null
	sv2v mom/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv mem/rtl/*.sv \
	  sys/rtl/hydra_engine_tpu_dma.sv sys/rtl/hydra_engine_gpu.sv sys/rtl/hydra_abi_v2.sv \
	  sys/rtl/hydra_sys_tile.sv sys/tb/tb_sys_tile_abi.sv > $(SIMTMP)/hydra_systile_abi.v
	iverilog -g2012 -I $(PIXELSTORM)/rtl -o $(SIMTMP)/hydra_systile_abi $(SIMTMP)/hydra_systile_abi.v $(PIXELSTORM)/rtl/ps_*.v
	$(SIM) --show '^(PASS|FAIL|[0-9] )' -- vvp -n $(SIMTMP)/hydra_systile_abi +dir=$(SIMTMP)/gpuvec_abi/07_matmul

systile-tpu:                  ## the dispatcher scheduling the REAL array
	python3 sys/tb/tpu_pattern_model.py 4 > /dev/null
	sv2v mom/rtl/*.sv common/rtl/mom_xbar.sv engines/tpu/rtl/*.sv \
	  sys/rtl/hydra_engine_tpu.sv sys/rtl/hydra_sys_tile.sv \
	  sys/tb/tb_sys_tile_tpu.sv > $(SIMTMP)/hydra_systile_tpu.v
	iverilog -g2012 -o $(SIMTMP)/hydra_systile_tpu $(SIMTMP)/hydra_systile_tpu.v
	$(SIM) --tail 4 -- vvp -n $(SIMTMP)/hydra_systile_tpu

lint:                         ## Verilator -Wall: the tile netlist and the OpenFrame chip, zero warnings
	SIMTMP=$(SIMTMP) ./tools/lint/lint.sh

sky130:                       ## the chip through its pads: pad mux, bring-up, SPI
	sv2v mom/rtl/*.sv mom/hydra_mom_pins.sv common/rtl/hydra_rst_sync.sv \
	  common/rtl/hydra_padmux.sv \
	  sky130/rtl/hydra_openframe_top.sv > $(SIMTMP)/hydra_of.v
	iverilog -g2012 -o $(SIMTMP)/hydra_of $(SIMTMP)/hydra_of.v sky130/tb/tb_openframe.sv
	$(SIM) --tail 2 -- vvp -n $(SIMTMP)/hydra_of

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
	python3 tools/drt_progress.py --selftest
	python3 tools/harden_ladder.py --selftest

boards:                       ## board files still match their vendor sources
	python3 tools/import_boards.py check

bind:                         ## generated board files still match plan + RTL
	@for p in plans/*.yaml; do python3 tools/hydra_bind.py check --plan $$p; done

mutate:                       ## slow: every test must be able to fail
	cd common/formal && python3 mutate_targets.py
	python3 mem/formal/mutate_dma.py
	python3 tools/mutate_mom.py
	python3 tools/mutate_cost_mux.py
	cd $(TILE) && python3 test/mutate_sim.py

clean:
	rm -rf fpga/build/*/{*.v,*.json,*.config,*.asc,*.bin,*.bit} \
	       common/tb/padmux_vectors.hex $(TILE)/test/sim_build common/formal/*_prove \
	       common/formal/*_cover tt/formal/*_prove tt/formal/*_cover

check-deps:                   ## every tool and Python package make verify needs, named up front
	@./scripts/check_deps.sh

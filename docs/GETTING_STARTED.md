# Getting started: your first simulation

This page gets you from a clone to a passing check. For tapeout and release
preparation, see [FIRST_TRY.md](FIRST_TRY.md), which is a different job.

## 1. What you need

- **Ubuntu 24.04**, which CI uses. Other Linux systems work if the same tools
  are installed.
- About 2 GB of disk space.
- `sudo` for the system packages, unless you install them yourself.

Board programming and ASIC hardening need more tools. You don't need them
here.

## 2. Clone and install the tools

```bash
cd ~/src && git clone --recurse-submodules https://github.com/Normansrule/hydra-skywater130.git && cd hydra-skywater130 && less scripts/bootstrap-ubuntu.sh
```

Read the script before running it. It installs apt packages with `sudo`, and
it downloads sv2v and yices from their GitHub releases. Python packages go
into `.venv`, unless you pass `--system`. Pass `--no-apt` if you install the
system packages yourself.

```bash
cd ~/src/hydra-skywater130 && ./scripts/bootstrap-ubuntu.sh && make bootstrap
```

`make bootstrap` fetches the board vendors' pin files and then runs
`make doctor`, which names any tool that is still missing.

## 3. One focused check at a time

Each command takes from seconds to a couple of minutes. A check passes only
if its last line starts with `PASS` (or `DONE (PASS` for a proof) **and**
`make` exits 0. Every simulation runs through `scripts/runsim.sh`, which
fails on a non-zero exit, on any `FAIL` line, or when the `PASS` line is
missing.

| command | what it checks | the line to expect |
|---|---|---|
| `make cost-cal` | the scheduler's cost and calibration arithmetic, compared with exact products | `PASS tb_cost_cal: 41076 cost products within 1/256 of exact; …` |
| `make tpu` | the 4×4 array against an independent model, plus its controller proof | `PASS tb_tpu: 40 cases, 640 results exact against the model` |
| `make systile` | the scheduler, the crossbar and the latency models over SPI | `PASS tb_sys_tile` |
| `make harness` | the FPGA host bridge, simulated over its serial port | `PASS tb_fpga_harness` |

## 4. The whole suite

```bash
cd ~/src/hydra-skywater130 && make -k verify 2>&1 | tee verify.log
```

`make verify` runs every simulation, proof and consistency check it lists.
The run time depends on your machine (tens of minutes). It does **not**
program a board, harden a chip or prove anything about the whole system. The
[capability matrix](verification/capability-matrix.md) says what each part
has and has not been shown to do.

## 5. When a check fails

The failing line names the check. `runsim.sh` keeps the full log and prints
its path. If a tool is missing, `make doctor` names it. If the design is at
fault, the failure message says what was expected and what came out. Please
report it with the log.

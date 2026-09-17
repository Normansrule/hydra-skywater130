# Runbook: from a fresh Ubuntu machine to a public repository

Every command below is meant to be pasted into an Ubuntu terminal in order.
Lines starting with `#` are comments. Anything you must supply yourself is in
`<angle brackets>`.

Assumed: Ubuntu 24.04 or newer (26.04 works; the bootstrap script does not
pin a release), a normal user account with `sudo`, and a GitHub account.

---

## 0. What you downloaded

| file | what to do with it |
|---|---|
| `hydra-skywater130-repo.zip` | unzip; this becomes the new public repository |

The tile patch ships **inside** the zip, at `tt/0001-session-179-tile.patch`,
so this is the only file you need.

### On Windows Subsystem for Linux (WSL)

The browser saves to Windows, and the Linux side has no `~/Downloads` at all.
Find the file and copy it into the Linux filesystem — do not work from
`/mnt/c`, where builds are slow and file permissions do not behave:

```bash
# The glob matters: Windows saves a second download as
# "hydra-skywater130-repo (1).zip", so an exact-name match quietly picks the
# OLD file and you unpack a stale copy.
ZIP=$(ls -t /mnt/c/Users/*/Downloads/hydra-skywater130-repo*.zip 2>/dev/null | head -1)
echo "$ZIP"                      # must print a path, and the one you expect
mkdir -p ~/src && rm -rf ~/src/hydra-skywater130
cd ~/src && unzip -q "$ZIP"
cd ~/src/hydra-skywater130 && pwd
```

Always unpack into a directory that does not exist yet. Unzipping over an old
copy leaves stale files behind and prompts about overwrites, which is how a
missing `scripts/status.sh` turns into a confusing error later.

### On a native Linux machine

```bash
ls -l ~/Downloads/hydra-skywater130-repo.zip
mkdir -p ~/src && cd ~/src && unzip -q ~/Downloads/hydra-skywater130-repo.zip
cd ~/src/hydra-skywater130 && pwd
```

Do not go further until `pwd` prints the repository path. Every later step
depends on it, and running from the wrong directory makes the whole sequence
fail one line at a time.

---

## 1. Basic machine setup

```bash
sudo apt-get update
sudo apt-get install -y git curl unzip gh

git config --global user.name  "Aleksander J. Norman"
git config --global user.email "<the email on your GitHub account>"
git config --global init.defaultBranch main
```

Authenticate GitHub once:

```bash
gh auth login
gh auth status
```

In a headless terminal `gh` cannot open a browser; that is harmless, it prints
the URL and the one-time code for you to paste elsewhere. On WSL,
`sudo apt-get install -y wslu` makes it open the Windows browser instead.

**Check which account you are signed in as.** Everything below assumes
`Normansrule`:

```bash
gh api user -q .login          # expect: Normansrule
```

If it prints something else, `gh auth login` again with the right account and
`gh auth switch --user Normansrule`.

---

## 2. Move the tile to the right account, then update it

The tile currently lives at `N0rmansrule/tinytapeout-hydra` (with a zero) and
should live at `Normansrule/tinytapeout-hydra`. Pick one of the two routes.

**Route A — transfer (preferred if you still have the N0rmansrule account).**
Transferring keeps the history, the issues and, importantly, a redirect from
the old URL, so anything already pointing at it still resolves:

```bash
gh auth switch --user N0rmansrule         # or gh auth login as that account
gh api -X POST repos/N0rmansrule/tinytapeout-hydra/transfer -f new_owner=Normansrule
gh auth switch --user Normansrule
```

Accept the transfer if GitHub emails you about it, then:

```bash
mkdir -p ~/src && cd ~/src
[ -d tinytapeout-hydra ] || git clone https://github.com/Normansrule/tinytapeout-hydra.git
cd tinytapeout-hydra
git remote set-url origin https://github.com/Normansrule/tinytapeout-hydra.git
```

**Route B — re-push the history (if the old account is out of reach).** This
keeps every commit, is not marked as a fork, and needs nothing from the old
account because the source is public:

```bash
mkdir -p ~/src && cd ~/src
[ -d tinytapeout-hydra ] || git clone https://github.com/N0rmansrule/tinytapeout-hydra.git
cd tinytapeout-hydra
gh repo create Normansrule/tinytapeout-hydra --public \
  --description "HYDRA-130 TT-A: the Mathematical Operation MUX on a TinyTapeout tile"
git remote set-url origin https://github.com/Normansrule/tinytapeout-hydra.git
git push -u origin --all
git push origin --tags
```

Either way, confirm before going on:

```bash
git remote -v                             # origin -> Normansrule/...
git log --oneline -1                      # b179c6b Session 144: ...
gh repo view Normansrule/tinytapeout-hydra --json viewerPermission -q .viewerPermission
```

That last line must say `ADMIN` or `WRITE`.

Use **HTTPS** remotes, as above, not SSH. `gh auth login` stored an HTTPS
credential for the account you signed in as; an SSH key registered to a
different account would push as that other account, or be refused.

**If the tile has already been submitted to a shuttle**, the submission records
the repository URL. A transfer (route A) leaves a redirect and keeps working; a
re-push (route B) does not, so update the submission —
<https://tinytapeout.com/guides/change-project-repo/>.

### Apply the session-179 patch

```bash
cd ~/src/tinytapeout-hydra
git am ~/src/hydra-skywater130/tt/0001-session-179-tile.patch
git log --oneline -2
```

If `git am` refuses because your branch has moved past `b179c6b`:

```bash
git am --abort
git checkout -b session-179 b179c6b
git am ~/src/hydra-skywater130/tt/0001-session-179-tile.patch
# then merge or rebase onto your branch as you prefer
```

Check it before pushing — the tile's own tests, both personalities. This needs
the toolchain from section 3, so if you have not run that yet, do section 3
first and come back:

```bash
cd ~/src/tinytapeout-hydra/test && make
# expect: TESTS=17 PASS=17 FAIL=0
```

Push:

```bash
cd ~/src/tinytapeout-hydra
git push origin HEAD
```

A `403 ... denied to <name>` means the signed-in account cannot write to that
repository: settle the account question in section 1 first.

---

## 3. Set up the new repository

```bash
cd ~/src
unzip -q ~/Downloads/hydra-skywater130-repo.zip     # creates ~/src/hydra-skywater130
cd ~/src/hydra-skywater130
pwd                                                  # confirm before continuing
```

Everything after this runs **inside** `~/src/hydra-skywater130`. If a command
fails with "No such file or directory", check `pwd` first: running the rest
from `~/src` is what turns one missing file into a page of errors.

Install the toolchain. Takes a few minutes; it is safe to run twice:

```bash
./scripts/bootstrap-ubuntu.sh
source .venv/bin/activate
```

It ends with a version table. If anything says `MISSING`, stop and fix it —
a check that cannot run is not a check that passed.

Pull in the tile sources and the board pin files:

```bash
pwd                                    # must end in /hydra-skywater130
git init -b main                       # needed before adding a submodule
./scripts/setup-tile.sh                # submodule -> your tinytapeout-hydra
python3 tools/import_boards.py fetch   # vendor constraint files, ~250 kB
```

If you forked the tile, `TILE_URL` from section 1 is picked up automatically.

`setup-tile.sh` will refuse if your tile repository does not contain session
179 yet, which is why section 2 comes first.

---

## 3b. Lost track of where you are?

```bash
cd ~/src/hydra-skywater130 && ./scripts/status.sh
```

It checks the toolchain, the tile checkout (and whether it contains session
179), the vendor pin files, whether the repository is published, and which
board builds exist. It changes nothing and ends with the next command to run.

Two things it will catch that cost time otherwise: running from the wrong
directory (every command fails with "No such file or directory" — check `pwd`
first), and a conda environment shadowing the virtual environment.

---

## 4. Verify everything locally

```bash
make verify
```

Expected, in order:

```
padmux   PASS tb_hydra_padmux: 20000/20000 vectors exact
         DONE (PASS) x3            (pad mux, reset sync, SPI target proofs)
tile     TESTS=17 PASS=17 FAIL=0
diff     PASS tb_v1_v2_diff        (400,000 cycles, 0 differences vs v1)
harness  PASS tb_fpga_harness
tools    29 passed
boards   boards: 10 files match their vendor sources
bind     3 boards: generated files match the plan and the RTL
=== all checks passed ===
```

The slow one, roughly 10 minutes, breaks each behaviour on purpose:

```bash
make mutate
# expect: === ALL MUTATIONS KILLED === and 14/15 sabotages caught
```

---

## 5. Publish it

```bash
cd ~/src/hydra-skywater130
./scripts/create-github-repo.sh hydra-skywater130
```

That commits, creates a **public** repository, pushes, and prints the URL. To
watch the CI run:

```bash
gh run watch
```

If you would rather not use the GitHub CLI:

```bash
git add -A
git commit -m "HYDRA-130 targets: TinyTapeout v2, FPGA bench platform, sky130 plan"
git remote add origin git@github.com:<you>/hydra-skywater130.git
git push -u origin main
```

Then set the repository to public in its settings.

---

## 6. Build for an FPGA board

Pick the plan that matches your board. ULX3S is the one that has been placed
and routed; Arty and Tang Nano are generated but have not been built here.

```bash
cd ~/src/hydra-skywater130
python3 tools/hydra_bind.py build --plan plans/ulx3s-85f.yaml
cd fpga/build/ulx3s-85f
make                     # sv2v -> yosys -> nextpnr-ecp5 -> ecppack, ~6 minutes
```

Expected at the end of the nextpnr output:

```
Info: Max frequency for clock '$glbnet$c_clk': 16.37 MHz (PASS at 12.50 MHz)
```

Flash it (ULX3S, over USB). Ubuntu 24.04 does not package `fujprog`;
`openFPGALoader` does the same job and is in the archive:

```bash
sudo apt-get install -y openfpgaloader
openFPGALoader -b ulx3s hydra_ulx3s_tt.bit          # volatile, gone at power off
openFPGALoader -b ulx3s -f hydra_ulx3s_tt.bit       # write to flash instead
```

`unable to open ftdi device: -3 (device not found)` means no board is visible.
On WSL that is expected: USB devices do not reach Linux unless `usbipd-win`
attaches them from Windows. Either do that, or copy the `.bit` to Windows and
flash it with the Windows build of openFPGALoader — the bitstream is the same
file either way.

If it cannot open the device, add yourself to `dialout` (section 7) or run it
once with `sudo`. On WSL the board is not visible to Linux at all without
`usbipd-win` attaching it; flashing from Windows is usually simpler.

Other boards:

- **Arty A7-35 / Nexys / Genesys 2** need Vivado. `build.tcl` is generated:
  `vivado -mode batch -source build.tcl`
- **Tang Nano 20K** needs the open Gowin flow: `pip install apycula` (already
  in the virtual environment) plus `nextpnr-himbaechel`, which Ubuntu does not
  package — build it from <https://github.com/YosysHQ/nextpnr> if you want it.
- **DE10-Lite** needs Quartus; a `project.qsf` is generated.

To add a board that is not in `fpga/boards/`, add a profile to
`tools/import_boards.py` pointing at that vendor's constraint file, run
`python3 tools/import_boards.py fetch build`, then copy a plan.

---

## 7. Run it on the bench

Find the serial port:

```bash
ls -l /dev/serial/by-id/          # or: dmesg | tail -20 after plugging in
sudo usermod -aG dialout "$USER"  # then log out and back in, once
```

Then:

```bash
python3 tools/hydra_host.py --port /dev/ttyUSB0 selftest
```

Expected:

```
1. identity      0x48594d32 ok
2. crossover     4x4x4 -> SIMD (margin 32), 8x8x8 -> TPU (margin 145) ok
3. retune        TPU setup 64 -> 4000 moves 8x8x8 to SIMD ok
4. calibration   decision left the TPU after ~19 slow completions ok
SELFTEST PASS
```

Those four lines are the whole argument for the design, running on hardware.

Useful variants:

```bash
python3 tools/hydra_host.py --port /dev/ttyUSB0 id
python3 tools/hydra_host.py --port /dev/ttyUSB0 dispatch -m 16 -n 16 -k 16 --bytes 768
python3 tools/hydra_host.py --port /dev/ttyUSB0 calibrate --slow-us 400 -n 60
```

On Windows the same script works with `--port COM8`.

---

## 8. Harden the tile for a shuttle

Not done yet, and it is the one number missing for the TinyTapeout target:
v2's area. Push the tile (section 2) and let its GitHub action build the GDS,
then read utilisation and timing. `docs/TAPEOUT.md` says what to read, in what
order, and what to drop first if it does not fit.

---

## 8b. If an earlier attempt left a mess

Running the sequence from the wrong directory can leave a stray repository at
`~/src`. Check and remove it — it is empty of commits, and leaving it there
confuses `gh` ("failed to determine base repo") and git alike:

```bash
git -C ~/src log --oneline -1 2>&1 | head -1     # expect: does not have any commits yet
rm -rf ~/src/.git                                # only if the line above says that
```

To start section 3 over from a clean state:

```bash
rm -rf ~/src/hydra-skywater130
```

The tile clone at `~/src/tinytapeout-hydra` can stay; `git am` is the only
thing that changes it, and it refuses rather than half-applying.

## 9. What is still blocked on you

The full sky130 chip needs two things I could not see:

```bash
cd ~/hydra
zip -r ~/hydra-snapshot.zip . -x '*/.git/*' -x '*/runs/*'
./tools/verify_all.sh soc 2>&1 | tail -40
cat /tmp/verify_all_soc_0.log | tail -60
grep -i "DIE_AREA\|CORE_AREA\|FP_SIZING" -r openlane/ tools/ | head
```

Send the snapshot and those outputs. `THREE_TARGETS.md` section 2 explains
what they settle: whether `global_route` is failing because the die is too
small for the cell area, which the arithmetic there suggests it is.

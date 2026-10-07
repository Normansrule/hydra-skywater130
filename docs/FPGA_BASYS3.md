# Bringing up the Digilent Basys 3

**Every command block assumes a brand new terminal.** Blocks starting `PS>`
run in Windows PowerShell; everything else runs in WSL (Ubuntu).

---

## 1. The board

**Digilent Basys 3**, an **AMD (Xilinx) Artix-7 XC7A35T-1CPG236C**: 20,800
six-input lookup tables, 41,600 flip-flops, 90 DSP (Digital Signal Processing)
slices, 50 block RAMs of 36 kilobits. A 100 MHz oscillator, 16 switches,
16 LEDs, 5 buttons, a four-digit seven-segment display, and an FTDI FT2232HQ
providing both programming and a USB serial port over one micro-USB cable.

| document | what it is for |
|---|---|
| **Basys 3 Reference Manual** (Digilent) | power, switches, buttons, display, LEDs, the USB serial port |
| **Basys-3-Master.xdc** (Digilent) | every pin — kept unmodified in `fpga/boards/basys3/` |
| **DS180**, 7 Series FPGAs Data Sheet: Overview (AMD) | the Artix-7 family's resources |
| **DS181**, Artix-7 Data Sheet: DC and AC Switching Characteristics (AMD) | electrical limits and timing |

Digilent's board page links the manual and constraints:
<https://digilent.com/reference/programmable-logic/basys-3/start>. AMD's data
sheets are at <https://docs.amd.com> — search the document number.

**Where the pins come from.** The design's top-level ports are named exactly
as in Digilent's master constraints file, and `tools/gen_basys3_xdc.py`
builds the constraints by **uncommenting Digilent's own lines** for those
ports. No pin is retyped, so none can be mistyped, and the generator fails if
the design names a port Digilent's file doesn't have.

---

## 2. Before powering on

- **Power jumper JP2 to USB.** The board runs from the micro-USB cable.
- **Mode jumper JP1 to JTAG** for loading over USB.
- All sixteen switches **down** (off).

---

## 3. The toolchain

Two options; the first is the one to use.

**Vivado (AMD), free edition.** The vendor tool, complete and reliable for
this device. It is a large download and needs a free AMD account. Install the
free *Vivado ML Standard* edition with Artix-7 support, then:

```bash
source /tools/Xilinx/Vivado/*/settings64.sh
vivado -version
```

(Adjust the path to wherever the installer put it.)

**Open-source alternative.** The openXC7 flow (Yosys, nextpnr-xilinx, Project
X-Ray) targets this exact chip and needs no account, but it is less mature
than Vivado. Use it if Vivado is not an option; expect rougher edges.

**Programming tool,** either way:

```bash
sudo apt install -y openfpgaloader python3-serial
```

---

## 4. Make the board visible to WSL

Same as any FTDI board. In PowerShell **as Administrator**, with the board
plugged in:

```powershell
PS> usbipd list
```

Find the line with `0403:6010` (the FT2232HQ), note its BUSID, then — using
the BUSID you just read, for example `2-4`:

```powershell
PS> usbipd bind --busid 2-4
PS> usbipd attach --wsl --busid 2-4
```

Back in WSL:

```bash
lsusb | grep -i 0403
ls /dev/ttyUSB*
```

Two serial ports appear; the **second, `/dev/ttyUSB1`, is the board's serial
port**.

---

## 5. Simulate, build, flash

Simulate first — if this fails there is no point touching the board:

```bash
cd ~/src/hydra-skywater130
make basys3-selftest
```

Expect `PASS tb_basys3_selftest: 9 checks`. Then build with Vivado:

```bash
cd ~/src/hydra-skywater130
source /tools/Xilinx/Vivado/*/settings64.sh
make basys3-bit
```

The build **refuses to write a bitstream that misses timing**: a board that
works most of the time is the hardest fault there is. Open a serial terminal
in a second window first, then flash:

```bash
python3 -m serial.tools.miniterm /dev/ttyUSB1 115200
```

```bash
cd ~/src/hydra-skywater130
make flash-basys3
```

---

## 6. The test

| # | do this | you should see | if not |
|---|---|---|---|
| 1 | flash | display shows **`HYdr`** for two seconds; LEDs 0–7 walk, twice | blank: no bitstream or no clock. Every segment *except* the right ones lit: display polarity inverted |
| 2 | watch the terminal | `HYDRA-130 SELFTEST OK` | nothing: wrong `ttyUSB`, or WSL not attached |
| 3 | press the **centre** button | `HYdr` and the walk replay | the centre button is the reset |
| 4 | flip switches 8–15 | LED *n* follows switch *n* | note which LED, then check the display (row 6) |
| 5 | hold **up**, **down**, **left**, **right** in turn | LEDs 8–15 show `11110000`, `00001111`, `10101010`, `01010101` | the pattern says which button the FPGA saw |
| 6 | after the banner, flip any switches | the display shows all sixteen as four hex digits; switch 15 is the top bit of the **left** digit | digits in the wrong order mean an anode mapping fault |
| 7 | switch 7 off, flip switches 0–6 | LEDs 0–6 follow; LED 7 blinks once a second | the shared core's mirror mode |
| 8 | switch 7 on, flip switch 2 | `011` blinks three times on LEDs 0–2 | the shared core names the switch |
| 9 | type a character | it comes back | receive path, pin B18 |

**Rows 4 and 6 locate faults together.** If LED 9 stays dark but the display's
second hex digit changes when you flip switch 9, the switch works and the
fault is the LED. If neither changes, it's the switch.

---

## 7. Why the Basys 3, against the ECP5 board

| | Basys 3 | ECP5 evaluation board |
|---|---|---|
| FPGA | Artix-7 XC7A35T | ECP5-5G LFE5UM5G-85F |
| Logic | 20,800 LUT6 | 84,000 LUT4 |
| On-board I/O | 16 LEDs, 16 switches, 5 buttons, display | 8 LEDs, 8 switches, buttons |
| Price | inexpensive, widely stocked | more expensive |
| Toolchain | Vivado (free), or openXC7 | fully open source |

The Basys 3 is the better bring-up and teaching board: more to see and touch,
and it is the board most students already have. The ECP5 board has four
times the logic and a fully open toolchain, which matters for the larger
HYDRA images.

**What fits.** The bring-up image uses about 1% of the Artix-7. The larger
HYDRA images have not yet been built for this chip; the two-engine image used
17,918 four-input lookup tables on the ECP5, and six-input tables pack more
logic each, but whether it fits is a question for a real build, not an
estimate.

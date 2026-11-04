# SunsoftGA9201 for Analogue Pocket (pre-release)

The SunsoftGA9201 core (Shanghai III, Hebereke no Popoon, Blocken) for the
Analogue Pocket (openFPGA). The game hardware is the same HDL as the MiSTer
core (`rtl/`, `ext/`); only the platform layer differs:

| | MiSTer | Pocket |
|---|---|---|
| Framework | `sys/`, `SunsoftGA9201.sv` | Analogue APF (`src/fpga/apf/`), `src/fpga/core/core_top.sv` |
| ROMs | MRA, MAME zips | one `.rom` file per game + an instance `.json` |
| ROM storage | SDRAM | SDRAM (same controller) |
| Display frame buffer | DDR3 | the two cellular RAM (PSRAM) chips (`rtl/pocket_fb.sv`, `rtl/pocket_cram.sv`) |
| Settings | OSD | Pocket menu (Core Settings) |

**Status:** simulation only, not yet built or tried on a Pocket. In
`scripts/sim_pocket.sh`, Shanghai III loads over the APF bridge (SDRAM image
identical to the MiSTer download) and runs 450 frames identical to the MiSTer
core's end-to-end simulation (every frame and the SDRAM access count), with
the blitter held exactly 86016 clocks at every vblank and no PSRAM protocol
errors.

## Installing

1. Copy the `Cores`, `Platforms` and `Assets` folders from the release zip to
   the root of the Pocket's SD card.
2. Make the ROM files (see below) and put them in `Assets/ga9201/common/`:
   `shangha3j.rom`, `heberpop.rom`, `blocken.rom`.
3. On the Pocket: openFPGA → Sunsoft GA9201 → pick a game.

### Making the .rom files

Each `.rom` is the byte stream the MiSTer MRA builds from the MAME 0.289 zips.
With Python 3, from a copy of this repository:

    python3 pocket/scripts/make_roms.py <folder with the MAME zips> <output folder>

It CRC-checks every ROM part. Tools that turn an MRA into a `.rom` (for example
`mra -A`) produce the same files from `releases/*.mra`.

## Controls and settings

A / B / X = buttons 1 / 2 / 3 (button 3 is used by Blocken), Start, Select =
coin, R = service. Remap them in the Pocket's controller settings.

Core Settings:
- **Reset Core**
- **Service Mode** (as the PCB's test switch)
- **OKI balance** (drums/FX volume; "PCB" is the measured balance)
- **Pause in menu**
- **Frame buffer**: *PSRAM* (default) is tear-free and timed exactly like the
  MiSTer core. *Direct* scans the picture straight out of the blitter's
  buffer: a fallback if the PSRAM path misbehaves; it can tear and shows each
  frame one frame earlier. Takes effect after Reset Core.

DIP switches use each game's defaults (from the MRA), set by the game's
`.json` in `Assets/ga9201/AjaxHC.SunsoftGA9201/` (`0x20000004`: SW1 in bits
7-0, SW2 in bits 15-8).

## Save states and sleep

Memories (save / load state) and sleep work in all three games. Notes:
- A save is refused for the first ~17 seconds after the game starts (the
  games' power-on RAM tests move the CPU's stack, so it can't be saved there).
- After loading, the picture takes a few frames to redraw. Sound picks up
  with the next notes (the sound chips themselves aren't saved yet, so a note
  that was playing at the save point is lost).
- A state only loads into the same game.


Quartus Prime Lite (17.0 or later), project `pocket/src/fpga/ap_core.qpf`.
Then, on Windows:

    powershell -ExecutionPolicy Bypass -File pocket\scripts\make_pocket_release.ps1

which bit-reverses `output_files/ap_core.rbf` into `bitstream.rbf_r` and
writes `pocket/output/SunsoftGA9201_Pocket_<date>.zip` (SD-card layout, no
ROMs).

## How it differs inside

- **Clocks:** one PLL from the Pocket's 74.25 MHz makes the 96 MHz core clock
  and the 8 MHz pixel clock (+90 degrees) from the same VCO.
- **Loading:** `rtl/pocket_loader.sv` turns the APF bridge writes of the ROM
  data slot into the MiSTer's `ioctl` byte stream (with `ioctl_wait`), so the
  core's memory system is unchanged.
- **Frame buffer:** the MiSTer keeps the display buffer in DDR3; the Pocket has
  none. `rtl/pocket_fb.sv` offers the same port the video module uses and
  stores 4 pixels per 48-bit entry, even words in PSRAM chip 0 and odd ones in
  chip 1, in synchronous burst mode at 48 MHz. It keeps up with the vblank
  copy, so the blitter is held for exactly the same 86016 clocks as on the
  MiSTer (checked in simulation for every frame).
- **SDRAM:** the Pocket's SDRAM has no chip select; cycles where the shared
  controller deselects are turned into NOPs.
- **Save states:** `rtl/pocket_ss_bridge.sv` connects the APF save/load
  commands to the board's state port (`rtl/shangha3_board.sv`, "Save states"):
  the 68000 saves its own registers through a small injected interrupt
  handler, the blob (128 KB at bridge address 0x40000000) holds work RAM,
  palette and a header, and a load restores the CPU the same way.

## Simulation

    pocket/scripts/sim_pocket.sh "releases/Shanghai III (Japan).mra" <romdir> <frames> \
        [--frames-out DIR --every N] [--direct] [--release-at CYCLE]

Loads the ROMs through the bridge (one word per ~1 us, as the Pocket does),
checks the SDRAM image, runs the game with two PSRAM models
(`sim/cram_model.sv`: variable latency, refresh collisions, row-boundary
stalls) and reports the PSRAM protocol errors and the blitter hold time per
frame. With the same `--release-at`, `scripts/sim_top.sh` (MiSTer path) gives
frames to compare. `--ss-test N` saves a state at frame N through the
bridge, runs on, loads it and compares (build with
`VFLAGS="+define+SS_SIM_GUARD=650"` to allow saves from frame 650);
`pocket/scripts/ss_bridge_test.sh` checks the bridge alone in seconds.

## Credits

Analogue's openFPGA core template (`src/fpga/apf/`, `core_bridge_cmd.v`, the
`core_top` port list). The I2S timing follows Adam Gastineau's
`sound_i2s.sv` (MIT); the PSRAM WAIT handling follows jotego's jtframe
Pocket controller (GPL-3.0). Everything else as in the main README.

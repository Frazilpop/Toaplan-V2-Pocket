# Pocket tools

These are the scripts that make the game files for the Analogue Pocket. The
ROMs you supply are written into `build/`. Run anything that opens the zips
with `python3 -I` so Python can't pick up stray files from the folder you're
in.

## Making the `.rom` files

```sh
python3 -I tools/pocket/build_rom.py batsugun ~/Downloads build/pocket     # one game
python3 -I tools/pocket/build_rom.py all      ~/Downloads build/pocket     # all games
python3 -I tools/pocket/verify_rom.py all --zipdir ~/Downloads             # verify against MAME
```

You can also give a list of ROM ids separated by commas, e.g. `batsugun,fixeight`.

The core supports the following ROM ids:

- Batsugun: `batsugun`, `batsuguna`, `batsugunc`, `batsugunb`, `batsugunsp`
- Dogyuun: `dogyuun`, `dogyuuna`, `dogyuunb`, `dogyuunt`
- Knuckle Bash: `kbash`, `kbashk`
- FixEight: `fixeight`, `fixeightk`, `fixeighth`, `fixeighttw`, `fixeighta`, `fixeightu`, `fixeightj`, `fixeightt`, `fixeightkt`, `fixeightht`, `fixeighttwt`, `fixeightat`, `fixeightut`, `fixeightjt`
- Grind Stormer and V-Five: `grindstm`, `grindstma`, `vfive`

The V25's opcode tables come from MAME's `toaplan_v25_tables.h` when
`tools/bootstrap.sh` has fetched it, and otherwise from the same tables as
the core holds them (`rtl/sound/*_decryption.hex`), so a plain download of
the repository is all `build_rom.py` needs. `verify_rom.py` needs MAME
itself, installed and on the path.

Each image starts with a 4 KB header, followed by every region of the set at
a fixed place for its board, with zeros in the gaps. The header tells the core
which board and game it is – clocks, memory map, the screen's rotation, the
DIP switches' defaults, where each region is – and carries the V25's 256-byte
opcode table, so one bitstream plays every set. Each board has its own size:

| board | games | regions | size |
|---|---|---|---|
| TP-030 | Batsugun | maincpu, gp9001_0, gp9001_1, oki | 0x6c1000 bytes |
| TP-022 | Dogyuun | maincpu, gp9001_0, gp9001_1, oki | 0x6c1000 bytes |
| TP-023 | Knuckle Bash | maincpu, audiocpu, gp9001_0, oki | 0x8c9000 bytes |
| TP-026 | FixEight | maincpu, gp9001_0, oki, eeprom | 0x4c1080 bytes |
| TP-027 | Grind Stormer, V-Five | maincpu, gp9001_0 | 0x281000 bytes |

The bytes go in as the board's loader takes them: each even byte paired with
the next into one 16-bit SDRAM word, the even byte in the low lane. So the
68000's program is stored as little-endian words of MAME's big-endian ones,
and each 32-bit block of the graphics holds a word of the region's lower half
and the same word of its upper half (all four planes of the same pixels, in
one SDRAM burst). The V25's ROM and the OKI's samples are bytes as MAME has
them. FixEight's factory EEPROM is MAME's region as it stands, and is what
the Pocket's save slot starts from.

The script finds each chip by its CRC32 and size, and will look through every
zip in the folder (the game's own zip and its parent's first), so merged, split
and non-merged sets all work. A `<rom id>/` folder of loose files works too.
The list of chips is copied from `ROM_START` in MAME's Toaplan drivers, in the
same order, so where chips overlap you get exactly what MAME gets.

`verify_rom.py` runs MAME with `tools/mame_toaplan2_regions.lua`, which saves
MAME's own copy of each region and its DIP defaults to
`build/mame/regions/<rom id>/` (`--no-mame` uses the ones already there), then
puts each region of the image back into MAME's order and compares them byte
for byte. It also checks the header, that every other byte is zero, and, for
Dogyuun's sets, the image against the order the upstream MiSTer core loads
its ROMs in.

For simulation, `--regions` writes one file per MAME region instead:

```sh
python3 -I tools/pocket/build_rom.py dogyuun ~/Downloads build/roms --regions
# build/roms/dogyuun_maincpu.bin, _gp9001_0.bin, _gp9001_1.bin, _oki.bin
```

## On the Analogue Pocket

Copy the image onto the SD card as

```
Assets/toaplan2/common/<rom id>.rom        e.g. Assets/toaplan2/common/batsugun.rom
```

Each game's instance JSON points at that file. The Pocket loads it at bridge
address 0, and the core reads the header first. FixEight's settings are kept
in its save file, which the Pocket writes when the core is closed; with none
yet, the core starts from the factory EEPROM in the image.

The Analogizer's settings come from the shared
`Assets/analogizer/common/analogizer.bin`, which Pupdate or
AnalogizerConfigurator writes.

## Checking against MAME

Everything from here on is for working on the core itself.

Run these through `mame_oracle.sh`. It gives each run a fresh, empty nvram and
cfg folder. MAME saves FixEight's 93C46 EEPROM when it quits and loads it
again when it starts, so otherwise every run would start from wherever the
last one left off. It also adds the flags autoboot needs (`-skip_gameinfo
-autoboot_delay 0`). `ROMS=` changes where it looks for ROMs (`~/Downloads`
by default) and `MAME=` changes which MAME it runs. `WAV_OUT=<file>` records
MAME's sound from power-on.

The top of each Lua script lists everything it writes, and what's in it.

```sh
# the 68000's bus from power-on
tools/pocket/mame_oracle.sh tools/mame_toaplan2_bus_trace.lua batsugun \
    BUS_TRACE_OUT=build/mame/batsugun_bus.txt BUS_TRACE_COUNT=200000
# the V25's bus, its port reads and its resets
tools/pocket/mame_oracle.sh tools/mame_toaplan2_v25_trace.lua batsugun \
    V25_TRACE_OUT=build/mame/batsugun_v25.txt
# the video state and MAME's picture at chosen frames, and the sound
tools/pocket/mame_oracle.sh tools/mame_toaplan2_dump.lua batsugun \
    DUMP_DIR=build/mame/dump/batsugun DUMP_FRAME=600,1800 \
    WAV_OUT=build/mame/batsugun_attract.wav
# a few events timed in board clocks (the V25's reset, the shared RAM)
tools/pocket/mame_oracle.sh tools/mame_toaplan2_events.lua batsugun \
    EVENTS_OUT=build/mame/batsugun_events.txt
# what the 68000 hands the V25, to feed the V25 on its own (make v25)
tools/pocket/mame_oracle.sh tools/mame_toaplan2_v25_feed.lua batsugun \
    V25_FEED_OUT=build/mame/batsugun_v25_feed.txt
```

Frame *N* is the *N*th frame MAME draws from power-on, and the harness counts
the same way.

## The simulation harness

`make sim` builds `build/obj_batsugun/tb_batsugun`: the whole board and its
SDRAM controller in Verilator, with jtframe's SDRAM model behind it, loaded
from the same `.rom` image the Pocket takes. Run `tools/bootstrap.sh` first.

```sh
build/obj_batsugun/tb_batsugun build/pocket/batsugun.rom 1800 build/sim/batsugun \
    --dump 600,1800 --trace build/sim/batsugun/bus.txt --wav build/sim/batsugun/attract.wav
python3 -I tools/pocket/compare_bus.py build/mame/batsugun_bus.txt build/sim/batsugun/bus.txt
python3 -I tools/pocket/compare_frame.py build/mame/dump/batsugun/f00600/screen.png \
    build/sim/batsugun/frame_00600.ppm --rot 270
python3 -I tools/pocket/compare_wav.py build/mame/batsugun_attract.wav \
    build/sim/batsugun/attract.wav --from 20 --to 30
```

- `compare_bus.py` compares two 68000 traces access for access and stops at
  the first difference; `--resync N` lets it skip polling loops of different
  lengths on the addresses that read the beam's position.
- `compare_frame.py` turns the harness's frame as MAME turns the game's
  screen and compares them pixel for pixel; `--diff` marks every pixel that
  differs.
- `compare_wav.py` compares the two sounds' loudness 10 ms at a time, finds
  the offset that lines them up, and then correlates the waveforms.

The harness's other options are listed at the top of
`sim/batsugun/tb_batsugun.cpp`: a plan of inputs a frame at a time
(`--inputs`, coin, start, the buttons and the D-pad for three players), the
V25's bus (`--v25-trace`), FixEight's EEPROM in and out (`--nv-in`,
`--nv-out`), checkpoints (`--save`, `--restore`) and the whole image
streamed through the loader (`--stream`).

The other benches:

- `make lint` – the board and the SDRAM controller through Verilator's lint.
- `make v25` – the V25 against upstream's own, clock for clock, on what MAME's
  68000 hands it (`mame_toaplan2_v25_feed.lua`).
- `make rotate` – Screen Rotation: the scaler setting and the turned D-pad for
  every game, setting and controller.
- `make anz` – the Analogizer: the harness built with the Analogizer module on
  the board's picture (`sim/batsugun/build.sh --anz`), then
  `check_analogizer.py`, which reads the cartridge pins in every video mode
  against the board's own frame, checks the pins are idle with the Analogizer
  off, and presses every button of SNES, NES and DB15 pads under every SNAC
  assignment.

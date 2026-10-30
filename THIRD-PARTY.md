# Third-party code and licences

This core is **GPL-3.0-only** as a whole, because fx68k is (see below). This
file lists each dependency and what its licence asks of us. The notices that
have to go with the bitstream are in `licences.txt`, beside it in the core's
folder.

## Fetched by `tools/bootstrap.sh`

These land in `third_party/`, pinned in `deps.lock`, and are never committed.

| Component | Licence | Used for |
|---|---|---|
| [jtfpga/fx68k](https://github.com/jtfpga/fx68k) | GPL-3.0-only | The 68000 main CPU |
| [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3.0-or-later | The OKI M6295 sound chip |
| [ika-musume/IKAOPM](https://github.com/ika-musume/IKAOPM) | BSD-2-Clause | The YM2151 sound chip |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | MIT | Pocket shell IP: data loader, I2S audio, sync FIFO |
| [mamedev/mame](https://github.com/mamedev/mame) (a sparse checkout) | BSD-3-Clause (the Toaplan files) | The reference, and the V25's opcode tables read at run time |

### fx68k – GPL-3.0-only
`deps.lock` pins `jtfpga/fx68k`, which is ijor's code repackaged for jtframe –
`hdl/fx68k.sv` is identical apart from line endings. Synthesis takes `hdl/`,
simulation takes its `hdl/verilator/` variant. The bootstrap symlinks
`microrom.mem` and `nanorom.mem` into the repo root, where fx68k loads them
from.

### jt6295 – GPL-3.0-or-later
Used as it is. The or-later clause is in each `hdl/` file header, and the
header counts, not `LICENSE` – re-read it after every `bootstrap.sh --update`.

### IKAOPM – BSD-2-Clause
© 2022 Raki. The YM2151, used as it is behind upstream's adapter
(`rtl/sound/dogyuun_opm.v`). The licence asks for its notice to go with the
bitstream, so it is in `licences.txt`.

### analogue-pocket-utils – MIT
© 2022 Adam Gastineau. `data_loader.sv`, `sound_i2s.sv` and `sync_fifo.sv`
are used as they are. Keep the notice.

### MAME – BSD-3-Clause (these files only)
The Toaplan drivers in `src/mame/toaplan/` – `batsugun.cpp`, `dogyuun.cpp`,
`kbash.cpp`, `fixeight.cpp` and `vfive.cpp` (the boards, clocks, memory
maps, inputs and ROM sets), `gp9001.cpp` and `toaplan_v25_tables.h` – are
BSD-3-Clause, © Quench, Yochizo and David Haywood. They are the only public
documentation of these boards. `tools/pocket/build_rom.py` reads the V25's
opcode tables from `toaplan_v25_tables.h` at run time rather than copying
them in; the FixEight table the bitstream holds,
`rtl/sound/dogyuun_ts001turbo_decryption.hex`, is that file's ts001turbo
table, and its notice is in `licences.txt`. FixEight's text layer
(`rtl/video/toaplan_text_layer.sv`) follows MAME's `toaplan_txtilemap`.

MAME as a whole is GPL-2.0, and `src/devices/` and `src/emu/` are a mix, so
check each file's header before transcribing anything else.

## In the tree

### TheJesusFish/Arcade-Dogyuun_MiSTer – GPL-3.0
The MiSTer core this is built on, imported at `89f75f5`: the board in
`rtl/board/` and `rtl/video/` – the 68000 bus, inputs, ROM loader, the
GP9001s' line renderers and mixer – and the V25 and its sound bus in
`rtl/sound/`. It builds on Erin Olafsen's (va7deo) Toaplan scaffolding and
Pramod Somashekar's (pram0d) GP9001, GPL-3.0, as upstream credits them.
Four of its files carry an SPDX BSD-3-Clause header with no copyright line
of their own – `dogyuun_v25_cpu.sv`, `dogyuun_sound.sv`,
`dogyuun_sound_mixer.sv` and `dogyuun_opm.v` – and keep it; their notice
is in `licences.txt`. The NITRO opcode table
(`rtl/sound/dogyuun_nitro_decryption.hex`) is upstream's, and MAME's.

### z8086 – Apache-2.0
`rtl/sound/v25_compact/` – the 8086 ALU and the microcode
(`batsugun_z8086_alu.sv`, `ucode.hex`) – and the V25 core in
`rtl/sound/dogyuun_z8086.sv` are derived from
[nand2mario/z8086](https://github.com/nand2mario/z8086) at `596d9a6`, © 2025
nand2mario, Apache-2.0, through upstream. Its `LICENSE` and `UPSTREAM.md` are
kept beside it. The V25's own registers, peripherals, opcode decryption,
clock enables and bus are upstream's changes and this core's. **The
reconstructed original Intel 8086 microcode's copyright status is
uncertain**, as z8086's README says; that notice is kept here, in
`UPSTREAM.md` and in `licences.txt`, which also carries the Apache licence's
full text, as it asks.

### jtframe – GPL-3.0-or-later
`rtl/jtframe/` is the handful of jtframe files the board and its SDRAM
controller use, as upstream vendored them: the dual-port RAMs, the ROM
request slots and caches, and `jtframe_sdram64`, the SDRAM controller, by
Jose Tejada (jotego). jtframe's `LICENSE` is beside them.
`sim/batsugun/sdram.cpp` and `sdram.h`, the harness's SDRAM model, are
jtframe's Verilator model, from the same vendored jtframe.

### RndMnkIII's Analogizer module – MIT, with GPL parts
`pocket/src/fpga/analogizer/` is the adapter module of RndMnkIII's
[Analogizer](https://github.com/RndMnkIII/Analogizer) (`analogizer/` at
`4b35f83`, © 2024 RndMnkIII, MIT), only the files it uses, as
`analogizer.qip` lists them. Three of them carry their own licences:
`yc_out.sv` (Mike Simone, GPL-2.0-or-later), `scandoubler.v` (Till Harbaum,
from MiST, GPL-3.0-or-later) and `vga_out_sw.v` (MiSTer's `vga_out`, by
Sorgelig, GPL). Two changes are made, marked in the files: the
scandoubler's pixel clock divider set for this board, and the PlayStation
pad reader left out – its `dualshock_controller.v` is free for
non-commercial use only, which the GPL does not allow.

### Analogue openFPGA core template – Analogue's APF Software License Agreement
`pocket/src/fpga/apf/`, `core_bridge_cmd.v` and the Quartus project files are
Analogue's, under the licence in their headers (with Analogue's Pocket EULA),
which yields to the MIT or GNU licence wherever the two disagree. The
Quartus megafunction output beside them (`mf_pllbase`, `pin_ddio_clk`,
`mf_datatable`, `mf_ddio_bidir_12`) is Intel's generated code, and
`build_id_gen.tcl` is Altera's reference design (Altera Reference Design
License), trimmed by Analogue.

## Written for this core

Everything else under `rtl/`, `sim/`, `tools/` and `pocket/` – what makes
upstream's Dogyuun board the other boards (Batsugun, Knuckle Bash, FixEight,
Grind Stormer), FixEight's text layer and EEPROM (`toaplan_text_layer.sv`,
`toaplan_93c46.sv`), the RAM the two processors share, the Pocket shell
(`core_top.v` and the `pocket_*` modules, its Analogizer wrapper among
them), the simulation harnesses and the tools – is GPL-3.0-or-later, as each
file's header says, or GPL-3.0 where it changes upstream's files (the
combination is GPL-3.0-only). The Pocket shell follows the one written for
Great 1000 Miles Rally.

`pocket/art/toaplan2-banner.png`, the platform image, is made from the
games' logos and artwork, © Toaplan.

## ROMs

No ROM images, or anything taken from them, are ever committed or distributed.
They're loaded at runtime, and tools that read them write only to `build/`.

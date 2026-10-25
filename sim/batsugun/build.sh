#!/usr/bin/env bash
# Build the board-level harness (tb_batsugun.sv + tb_batsugun.cpp). Run from
# the repository root; the binary is build/obj_batsugun/tb_batsugun.
#   sim/batsugun/build.sh [--anz] [extra verilator args]
# --anz (first) builds it with the shell's pocket_analogizer and RndMnkIII's
# module (pocket/src/fpga/analogizer/) on the board's raster, into
# build/obj_anz/: tb_batsugun's --anz-* options, for
# tools/pocket/check_analogizer.py.
set -euo pipefail
test -d third_party/fx68k || { echo "run tools/bootstrap.sh first"; exit 1; }
J=rtl/jtframe
anz=()
obj=${OBJ:-build/obj_batsugun}
mkdir -p build/tmp
export TMPDIR="$PWD/build/tmp"
if [ "${1:-}" = "--anz" ]; then
  shift
  obj=${OBJ:-build/obj_anz}
  # scandoubler.v's colour-depth branch for a remainder it never has here
  # selects zero bits, which Quartus passes over and Verilator refuses: the
  # harness compiles a copy with the width held at one
  sed 's/ -:n\]/ -:(n>0?n:1)]/g' pocket/src/fpga/analogizer/scandoubler.v > build/tmp/scandoubler_sim.v
  # serlatch_gc.v reads a seventeenth bit from NES and SNES pads into bit 16
  # of a 16-bit register: a write that does nothing (IEEE 1800 11.5.1, and
  # Quartus), which Verilator wraps onto bit 0, the pads' first button
  sed 's/^\( *\)\(p[12]b_r\[((counter>>1)-1)\] <= i_dat[12];\)/\1if (((counter>>1)-1) < 6'"'"'d16) \2/' \
    pocket/src/fpga/analogizer/serlatch_gc.v > build/tmp/serlatch_gc_sim.v
  # yc_out.sv's phase_t is an unpacked struct, which --savable cannot write
  # into a checkpoint: packed, it is the same bits
  sed 's/^typedef struct {/typedef struct packed {/' pocket/src/fpga/analogizer/yc_out.sv > build/tmp/yc_out_sim.sv
  anz=(+define+ANALOGIZER -CFLAGS -DANALOGIZER
    pocket/src/fpga/core/pocket_sync.sv pocket/src/fpga/core/pocket_analogizer.sv
    $(ls pocket/src/fpga/analogizer/*.v pocket/src/fpga/analogizer/*.sv | grep -v -e scandoubler.v -e serlatch_gc.v -e yc_out.sv)
    build/tmp/scandoubler_sim.v build/tmp/serlatch_gc_sim.v build/tmp/yc_out_sim.sv)
fi
mkdir -p "$obj"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  --savable -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  -DJTFRAME_BUTTONS=3 -DJTFRAME_MCLK=48000000 \
  --top-module tb_batsugun --Mdir "$obj" -o tb_batsugun \
  -CFLAGS "-O2 -std=c++17" ${anz[@]+"${anz[@]}"} "$@" \
  sim/batsugun/tb_batsugun.sv \
  rtl/board/*.sv rtl/video/*.sv rtl/sound/*.sv rtl/sound/*.v rtl/sound/v25_compact/*.sv \
  $J/ram/*.v $J/sdram/jtframe_rom_1slot.v $J/sdram/jtframe_rom_2slots.v \
  $J/sdram/jtframe_romrq*.v $J/sdram/jtframe_ramslot_ctrl.v $J/sdram/jtframe_sdram64*.v \
  third_party/fx68k/hdl/verilator/*.sv third_party/jt6295/hdl/*.v \
  third_party/IKAOPM/src/IKAOPM.v third_party/IKAOPM/src/IKAOPM_modules/*.v \
  sim/batsugun/tb_batsugun.cpp sim/batsugun/sdram.cpp

#!/usr/bin/env bash
# Build the board-level harness (tb_batsugun.sv + tb_batsugun.cpp). Run from
# the repository root; the binary is build/obj_batsugun/tb_batsugun.
#   sim/batsugun/build.sh [extra verilator args]
set -euo pipefail
test -d third_party/fx68k || { echo "run tools/bootstrap.sh first"; exit 1; }
J=rtl/jtframe
mkdir -p build/obj_batsugun build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  -DJTFRAME_BUTTONS=3 -DJTFRAME_MCLK=48000000 \
  --top-module tb_batsugun --Mdir "${OBJ:-build/obj_batsugun}" -o tb_batsugun \
  -CFLAGS "-O2 -std=c++17" "$@" \
  sim/batsugun/tb_batsugun.sv \
  rtl/board/*.sv rtl/video/*.sv rtl/sound/*.sv rtl/sound/*.v rtl/sound/v25_compact/*.sv \
  $J/ram/*.v $J/sdram/jtframe_rom_1slot.v $J/sdram/jtframe_rom_2slots.v \
  $J/sdram/jtframe_romrq*.v $J/sdram/jtframe_ramslot_ctrl.v $J/sdram/jtframe_sdram64*.v \
  third_party/fx68k/hdl/verilator/*.sv third_party/jt6295/hdl/*.v \
  third_party/IKAOPM/src/IKAOPM.v third_party/IKAOPM/src/IKAOPM_modules/*.v \
  sim/batsugun/tb_batsugun.cpp sim/batsugun/sdram.cpp

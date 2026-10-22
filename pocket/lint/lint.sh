#!/bin/sh
# Verilator lint of the Pocket shell against the real board, jtframe_sdram64
# and agg23's IP, with Intel primitives stubbed (altera_stubs.v). Run from
# anywhere.
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fpga=$repo/pocket/src/fpga
tp=$repo/third_party
j=$repo/rtl/jtframe
# The board's and the third-party files' own warnings surface late in
# elaboration, past the file waivers in lint.vlt, so the run does not stop on
# warnings; the script fails on an error or on any warning in the shell's
# own files.
out=$(mktemp)
trap 'rm -f "$out"' EXIT
verilator --lint-only -Wall -Wno-fatal --top-module core_top \
  -Wno-DECLFILENAME -Wno-MULTITOP \
  -DJTFRAME_BUTTONS=3 -DJTFRAME_MCLK=48000000 \
  "$here/lint.vlt" \
  "$here/altera_stubs.v" \
  "$fpga/apf/common.v" \
  "$fpga/core/mf_pllbase.v" "$fpga/core/mf_pllbase/mf_pllbase_0002.v" \
  "$fpga/core/pin_ddio_clk.v" \
  "$fpga/core/core_bridge_cmd.v" \
  "$tp/pocket-utils/ip/data_loader.sv" "$tp/pocket-utils/ip/sync_fifo.sv" "$tp/pocket-utils/ip/sound_i2s.sv" \
  "$repo"/rtl/board/*.sv "$repo"/rtl/video/*.sv "$repo"/rtl/sound/*.sv "$repo"/rtl/sound/*.v \
  "$repo"/rtl/sound/v25_compact/*.sv \
  "$j"/ram/*.v "$j/sdram/jtframe_rom_1slot.v" "$j/sdram/jtframe_rom_2slots.v" \
  "$j"/sdram/jtframe_romrq*.v "$j/sdram/jtframe_ramslot_ctrl.v" "$j"/sdram/jtframe_sdram64*.v \
  "$tp"/fx68k/hdl/verilator/*.sv "$tp"/jt6295/hdl/*.v \
  "$tp/IKAOPM/src/IKAOPM.v" "$tp"/IKAOPM/src/IKAOPM_modules/*.v \
  "$fpga/core/pocket_sync.sv" "$fpga/core/pocket_rom_loader.sv" \
  "$fpga/core/pocket_video.sv" "$fpga/core/pocket_diag.sv" "$fpga/core/pocket_nvram.sv" \
  "$fpga/core/core_top.v" "$@" > "$out" 2>&1 || { cat "$out"; exit 1; }
if grep -E "^%(Warning|Error)" "$out" | grep -E "pocket/src/fpga/core/(core_top|pocket_)"; then
    exit 1
fi
echo "lint: core_top and the pocket_* modules clean"

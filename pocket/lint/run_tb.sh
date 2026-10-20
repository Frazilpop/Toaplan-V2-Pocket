#!/bin/sh
# Build and run tb_shell.sv (Verilator --binary): the loading path and the
# video crossing. Build tree under build/. Usage: run_tb.sh [set.rom]
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fpga=$repo/pocket/src/fpga
out=$repo/build/pocket_tb
rom=${1:-$repo/build/pocket/batsugun.rom}
mkdir -p "$out"
verilator --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
  --top-module tb_shell -Mdir "$out" \
  "$here/tb_shell.sv" \
  "$repo/third_party/pocket-utils/ip/data_loader.sv" \
  "$fpga/core/pocket_rom_loader.sv" "$fpga/core/pocket_video.sv" \
  "$repo/rtl/board/dogyuun_rom_loader.sv" \
  > "$out/build.log" 2>&1 || { tail -40 "$out/build.log"; exit 1; }
"$out/Vtb_shell" +rom="$rom"

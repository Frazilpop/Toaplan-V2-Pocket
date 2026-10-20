# Toaplan V2 for the Analogue Pocket
#
#   make lint     verilator --lint-only of the board (dogyuun_game) and the
#                 SDRAM controller (jtframe_sdram64)
#   make clean
#
# Run tools/bootstrap.sh first: fx68k, jt6295 and IKAOPM are used in place
# from third_party/.

VERILATOR ?= verilator

JTFRAME   := rtl/jtframe
BOARD     := $(wildcard rtl/board/*.sv) rtl/board/savestate/ram_adaptor.sv \
             $(wildcard rtl/video/*.sv) \
             $(wildcard rtl/sound/*.sv rtl/sound/*.v) \
             $(wildcard rtl/sound/v25_compact/*.sv) \
             $(JTFRAME)/jtframe_bcd_cnt.v \
             $(JTFRAME)/clocking/jtframe_freqinfo.v \
             $(JTFRAME)/cpu/jtframe_68kdtack_cen.v \
             $(wildcard $(JTFRAME)/ram/*.v) \
             $(JTFRAME)/sdram/jtframe_rom_1slot.v $(JTFRAME)/sdram/jtframe_rom_2slots.v \
             $(wildcard $(JTFRAME)/sdram/jtframe_romrq*.v) \
             $(JTFRAME)/sdram/jtframe_ramslot_ctrl.v
SDRAM     := $(wildcard $(JTFRAME)/sdram/jtframe_sdram64*.v)
THIRD     := $(wildcard third_party/fx68k/hdl/verilator/*.sv) \
             $(wildcard third_party/jt6295/hdl/*.v) \
             third_party/IKAOPM/src/IKAOPM.v \
             $(wildcard third_party/IKAOPM/src/IKAOPM_modules/*.v)
# The modules left upstream (high scores, debug probes), as empty stand-ins.
STUBS     := sim/lint/dogyuun_left_upstream.sv

# Upstream's MiSTer project sets these for the board.
DEFINES   := -DJTFRAME_BUTTONS=3 -DJTFRAME_MCLK=48000000
# Upstream's code is linted as it stands: errors stop the lint, the width and
# timescale warnings it carries do not.
VFLAGS    := --lint-only -Wno-fatal -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND \
             -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT -Wno-CASEINCOMPLETE

.PHONY: lint clean
lint:
	@test -d third_party/fx68k || { echo "run tools/bootstrap.sh first"; exit 1; }
	$(VERILATOR) $(VFLAGS) $(DEFINES) --top-module dogyuun_game $(BOARD) $(THIRD) $(STUBS)
	$(VERILATOR) $(VFLAGS) --top-module jtframe_sdram64 $(SDRAM)
	@echo "lint: dogyuun_game and jtframe_sdram64 resolve, no errors"

clean:
	rm -rf obj_dir build/tmp

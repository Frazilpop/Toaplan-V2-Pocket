# Toaplan V2 for the Analogue Pocket
#
#   make lint     verilator --lint-only of the board (dogyuun_game) and the
#                 SDRAM controller (jtframe_sdram64)
#   make v25      the V25 wrapper against upstream's (eec1fc3), clock for
#                 clock, on a MAME feed: FEED=build/mame/dogyuun_v25_feed.txt
#                 (tools/mame_toaplan2_v25_feed.lua), CLOCKS=600000000,
#                 CEN=25 (12.5 MHz), SECURE=1 (nitro, Dogyuun; 0 for
#                 Batsugun's plain code, both wrappers alike):
#                 make v25 FEED=build/mame/batsugun_v25_feed.txt CEN=32 SECURE=0
#   make sim      the board-level harness, build/obj_batsugun/tb_batsugun
#                 (sim/batsugun/build.sh): the board and jtframe_sdram64
#                 with jtframe's SDRAM model, MAME as the oracle
#                 (tools/pocket/compare_bus.py, compare_frame.py,
#                 compare_wav.py)
#   make clean
#
# Run tools/bootstrap.sh first: fx68k, jt6295 and IKAOPM are used in place
# from third_party/.

VERILATOR ?= verilator

JTFRAME   := rtl/jtframe
BOARD     := $(wildcard rtl/board/*.sv) \
             $(wildcard rtl/video/*.sv) \
             $(wildcard rtl/sound/*.sv rtl/sound/*.v) \
             $(wildcard rtl/sound/v25_compact/*.sv) \
             $(wildcard $(JTFRAME)/ram/*.v) \
             $(JTFRAME)/sdram/jtframe_rom_1slot.v $(JTFRAME)/sdram/jtframe_rom_2slots.v \
             $(wildcard $(JTFRAME)/sdram/jtframe_romrq*.v) \
             $(JTFRAME)/sdram/jtframe_ramslot_ctrl.v
SDRAM     := $(wildcard $(JTFRAME)/sdram/jtframe_sdram64*.v)
THIRD     := $(wildcard third_party/fx68k/hdl/verilator/*.sv) \
             $(wildcard third_party/jt6295/hdl/*.v) \
             third_party/IKAOPM/src/IKAOPM.v \
             $(wildcard third_party/IKAOPM/src/IKAOPM_modules/*.v)

# Upstream's MiSTer project sets these for the board.
DEFINES   := -DJTFRAME_BUTTONS=3 -DJTFRAME_MCLK=48000000
# Upstream's code is linted as it stands: errors stop the lint, the width and
# timescale warnings it carries do not.
VFLAGS    := --lint-only -Wno-fatal -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND \
             -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT -Wno-CASEINCOMPLETE

SECURE    ?= 1
V25_REF   := build/v25/dogyuun_v25_cpu_ref_s$(SECURE).sv
V25_SRC   := rtl/sound/dogyuun_v25_cpu.sv rtl/sound/dogyuun_z8086.sv \
             rtl/sound/v25_compact/batsugun_z8086_alu.sv
FEED      ?= build/mame/dogyuun_v25_feed.txt
CLOCKS    ?= 600000000
CEN       ?= 25

.PHONY: lint v25 sim clean
lint:
	@test -d third_party/fx68k || { echo "run tools/bootstrap.sh first"; exit 1; }
	$(VERILATOR) $(VFLAGS) $(DEFINES) --top-module dogyuun_game $(BOARD) $(THIRD)
	$(VERILATOR) $(VFLAGS) --top-module jtframe_sdram64 $(SDRAM)
	@echo "lint: dogyuun_game and jtframe_sdram64 resolve, no errors"

$(V25_REF):
	mkdir -p build/v25
	git show eec1fc3:rtl/dogyuun/dogyuun_v25_cpu.sv | \
	    sed -e 's/^module dogyuun_v25_cpu /module dogyuun_v25_cpu_ref /' \
	        -e "s/\.secure_mode *(1'b1)/.secure_mode (1'b$(SECURE))/" > $@

v25: $(V25_REF)
	$(VERILATOR) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style \
	    -Wno-TIMESCALEMOD --Mdir build/v25/obj_s$(SECURE) --top-module tb_v25 \
	    sim/v25/tb_v25.sv $(V25_SRC) $(V25_REF) sim/v25/tb_v25.cpp \
	    -o Vtb_v25 > build/v25/build.log 2>&1 || { tail -30 build/v25/build.log; exit 1; }
	build/v25/obj_s$(SECURE)/Vtb_v25 $(FEED) $(CLOCKS) $(CEN) $(SECURE)

sim:
	sim/batsugun/build.sh > build/sim_build.log 2>&1 || { grep -m5 Error build/sim_build.log; exit 1; }
	@echo "sim: build/obj_batsugun/tb_batsugun"

clean:
	rm -rf obj_dir build/tmp build/v25 build/obj_batsugun

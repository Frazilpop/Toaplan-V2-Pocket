# Toaplan V2 for Analogue Pocket — core timing constraints
#
# Read by apf/apf_constraints.sdc (Analogue's, unmodified) after it has
# created clk_74a / clk_74b / bridge_spiclk and run derive_pll_clocks. Not
# listed in ap_core.qsf, so it is applied once.

# ------------------------------------------------------------------ clocks
#
# The PLL's output counters, by the path derive_pll_clocks gives them. The
# path is core_top's `mp1` -> mf_pllbase's `mf_pllbase_inst` -> `altera_pll_i`;
# renaming any level silently breaks every line below, so it is checked.
set pll_path {ic|mp1|mf_pllbase_inst|altera_pll_i}
set clk_sys      [get_clocks -nowarn "${pll_path}|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_sdram_ps [get_clocks -nowarn "${pll_path}|general\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_vid      [get_clocks -nowarn "${pll_path}|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_vid90    [get_clocks -nowarn "${pll_path}|general\[3\].gpll~PLL_OUTPUT_COUNTER|divclk"]

# An empty collection turns set_clock_groups and set_multicycle_path into
# silent no-ops and the build "passes" untimed — upstream's Kaneko16.sdc has
# the story. Here that is an error, not a warning.
foreach {name c} [list sys $clk_sys sdram_ps $clk_sdram_ps \
                       vid $clk_vid vid90 $clk_vid90] {
    if {[get_collection_size $c] == 0} {
        post_message -type error "core_constraints.sdc: PLL output '$name' not found under $pll_path. The constraints below would be no-ops; fix the path."
    }
}

# The SDRAM clock as the device sees it: clk_sdram_ps, forwarded through the
# DDIO output register in core_top (pin_ddio_clk, data 1/0) to the dram_clk
# pin. Quartus traces the path from the PLL counter through the I/O cell, so
# the pin-side clock carries the real output delay and the I/O constraints
# below are relative to the clock edge at the pin.
create_generated_clock -name dram_clk_pin \
    -source [get_pins "${pll_path}|general\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"] \
    [get_ports {dram_clk}]

# ---------------------------------------------------------- clock groups
#
# clk_74a (bridge, pad bus, I2S) is the PLL's reference but is treated as
# unrelated to its outputs: every path between them is crossed by a
# synchroniser, a dcfifo or a dual-clock RAM, and never by plain logic.
# Every one of them is listed in core_top.v.
#
# The PLL outputs are ONE group and are timed against each other, because
# two crossings depend on it:
#
#   94.5 -> 6.75  pocket_video: `hold` (94.5 MHz, loaded on ce_pix) sampled
#               on every 6.75 MHz edge. Every 6.75 MHz edge coincides with a
#               94.5 MHz edge, so this is a normal synchronous path. Timing it
#               is what makes "a 6.75 MHz edge on the reload edge sees the old
#               pixel" true in silicon, not just in the RTL comment.
#   94.5 -> pin   the SDRAM I/O below, against dram_clk_pin.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a}] \
    -group [get_clocks {clk_74b}] \
    -group [get_clocks {bridge_spiclk}] \
    -group [add_to_collection [get_clocks "${pll_path}|*"] [get_clocks {dram_clk_pin}]]

# ------------------------------------------------------------------ SDRAM
#
# AS4C32M16MSA-6 (1.8 V mobile SDR). Figures from the -6 grade of the same
# family's sheet (AS4C16M16MSA-6, Rev 1.0), CL = 2 as jtframe_sdram64 programs:
#
#   tCMS/tCAS  command/address setup  2.0 ns     tCMH/tCAH  hold  1.0 ns
#   tCDS       data-in setup          2.0 ns     tCDH       hold  1.0 ns
#   tAC(2)     access from clock      6.0 ns max tOH        hold  2.5 ns min
#
# Board traces are short (the SDRAM sits beside the FPGA); 0.2 ns allowed for
# a flight each way.
set sdr_trace 0.2

set sdr_out [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_dq[*]}]
set_output_delay -clock dram_clk_pin -max [expr {2.0 + $sdr_trace}] $sdr_out
set_output_delay -clock dram_clk_pin -min [expr {-1.0}]              $sdr_out

# Commands leave on a clk_sys edge and are sampled by the device on the next
# dram_clk_pin edge, half a period later. That is the default relationship, so
# no exception is needed for outputs.

# READ DATA, AS A TWO-CYCLE PATH, AS MILLE MIGLIA'S SHELL TIMES IT.
#
# Data appears tAC after a device clock edge, and the device clock is half a
# period behind clk_sys plus the I/O cell's output delay. The default
# analysis would latch it on the very next clk_sys edge -- half a period
# after launch -- which nothing could meet with the sheet's tAC; it is timed
# one full cycle later. On the Pocket the part was measured (Mille Miglia,
# 9 Oct 2026, the same pins and forwarding at 96 MHz) to have its word on
# the bus a clock earlier than this paper edge, which is the edge
# jtframe_sdram64 samples (three edges after the READ leaves its register);
# the overlay's flag 15 checks it on the 68000's first fetch.
set_input_delay -clock dram_clk_pin -max [expr {6.0 + 2 * $sdr_trace}] [get_ports {dram_dq[*]}]
set_input_delay -clock dram_clk_pin -min 2.5                           [get_ports {dram_dq[*]}]
set_multicycle_path -from [get_clocks {dram_clk_pin}] -to $clk_sys -setup -end 2
set_multicycle_path -from [get_clocks {dram_clk_pin}] -to $clk_sys -hold  -end 1

# CKE is a constant 1 from jtframe_sdram64; it has no timing to meet.
set_false_path -to [get_ports {dram_cke}]

# ------------------------------------------------------------ SRAM, PSRAM
#
# Not used: every pin is a constant (core_top.v), with no timing to meet.
set_false_path -to   [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n}]
set_false_path -to   [get_ports {cram0_* cram1_*}]

# ------------------------------------------------------------------ board
#
# Upstream's own exceptions for the board (Arcade-Dogyuun.sdc), re-rooted
# under core_top, as the board-alone fit uses them:
#
#   - the z8086 inside the V25 advances only on the V25's clock enable,
#     never more often than one clock in five (16 MHz of 94.5), and every
#     register in it is gated by that enable;
#   - fx68k's instruction register to its micro/nano address decode is a
#     two-cycle path, as fx68k documents.
set v25_cpu [get_keepers -nowarn {*|dogyuun_sound:u_sound|dogyuun_v25_cpu:u_v25|dogyuun_z8086:u_cpu|*}]
set fx_ir   [get_keepers -nowarn {*|dogyuun_main:u_main|fx68k:u_main68k|Ir[*]}]
set fx_ua   [get_keepers -nowarn {*|dogyuun_main:u_main|fx68k:u_main68k|microAddr[*]}]
set fx_na   [get_keepers -nowarn {*|dogyuun_main:u_main|fx68k:u_main68k|nanoAddr[*]}]
foreach {name c} [list v25_cpu $v25_cpu fx_ir $fx_ir fx_ua $fx_ua fx_na $fx_na] {
    if {[get_collection_size $c] == 0} {
        post_message -type error "core_constraints.sdc: board keepers '$name' not found. The exception below would be a no-op; fix the path."
    }
}
set_multicycle_path -setup -from $v25_cpu -to $v25_cpu 5
set_multicycle_path -hold  -from $v25_cpu -to $v25_cpu 4
set_multicycle_path -start -setup -from $fx_ir -to $fx_ua 2
set_multicycle_path -start -hold  -from $fx_ir -to $fx_ua 1
set_multicycle_path -start -setup -from $fx_ir -to $fx_na 2
set_multicycle_path -start -hold  -from $fx_ir -to $fx_na 1

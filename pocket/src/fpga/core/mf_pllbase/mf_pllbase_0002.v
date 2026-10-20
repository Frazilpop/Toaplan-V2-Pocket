// Toaplan V2 for Analogue Pocket — the core PLL.
//
// This is the template's Qsys-generated wrapper with its parameters edited by
// hand. The instance names (mf_pllbase -> mf_pllbase_inst -> altera_pll_i)
// are unchanged ON PURPOSE: core_constraints.sdc names the output counters
// by that path, and an .sdc that matches nothing constrains nothing.
//
// FREQUENCIES, FROM clk_74a = 74.25 MHz
//
// One VCO for everything, so every output is an integer divide of it and all
// of them are mutually synchronous:
//
//     VCO = 74.25 MHz x 112 / 11 = 756 MHz   (PFD 6.75 MHz, integer mode)
//
//   outclk_0   94.5 MHz  /8    the board, jtframe_sdram64, the loader: the
//                              board's own clock (upstream's "clk96", which
//                              its PLL makes as 94.5 = 14 x 6.75)
//   outclk_1   94.5 MHz  /8    SDRAM pin clock, 180 degrees (5291 ps) behind
//   outclk_2   6.75 MHz  /112  APF video_rgb_clock: the board's pixel rate
//                              (27 MHz / 4), one pixel a cycle
//   outclk_3   6.75 MHz  /112  video_rgb_clock_90, 90 degrees (37037 ps)
//
// All are exact. The SDRAM pin clock is forwarded through a DDIO output
// register (pin_ddio_clk) so that it leaves the FPGA through the same kind
// of I/O-cell register as the commands; its 180 degrees is 32 VCO
// eighth-steps (165.3 ps each), the 90 degrees of the video clock 224.

`timescale 1ns/10ps
module  mf_pllbase_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'outclk2'
	output wire outclk_2,

	// interface 'outclk3'
	output wire outclk_3,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("normal"),
		.number_of_clocks(4),
		.output_clock_frequency0("94.500000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("94.500000 MHz"),
		.phase_shift1("5291 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("6.750000 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("6.750000 MHz"),
		.phase_shift3("37037 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule


// SPDX-License-Identifier: GPL-3.0-or-later
// Toaplan V2 for Analogue Pocket — the core top level
//
// Instantiated by Analogue's apf_top. Everything Pocket-specific lives here and
// in the pocket_* modules beside it; the board itself (rtl/board/dogyuun_game.sv)
// knows nothing of APF, pins or the bridge.
//
// CLOCKS (core/mf_pllbase/mf_pllbase_0002.v has the derivation)
//
//   clk_74a        74.25 MHz  APF bridge, pad bus, I2S; PLL reference
//   clk_sys        94.5 MHz   the board, jtframe_sdram64, the loader, the
//                             overlay: one clock, as upstream's board runs
//   clk_sdram_ps   94.5 MHz   180 deg, forwarded to dram_clk
//   clk_vid        6.75 MHz   APF video bus, one pixel a clock
//   clk_vid90      6.75 MHz   90 deg, for APF's video DDR
//   clk_anz        27 MHz     the Analogizer (pocket_analogizer): four clocks
//                             a dot, and the adapter's DAC clock
//
// 94.5, 6.75 and 27 come from one VCO and are synchronous; everything they share
// with clk_74a crosses through a synchroniser, a dcfifo or a dual-clock RAM,
// and core_constraints.sdc cuts exactly those.
//
// BRIDGE MAP
//
//   0x00000000-   ROM image data slot -> the board's loader   pocket_rom_loader
//   0x20000000-   EEPROM save slot, 128 bytes, r/w (FixEight)   pocket_nvram
//   0xF1000000-   options (interact.json)                     r/w, see below
//   0xF7000000    analogizer.bin, the Analogizer's settings   pocket_analogizer
//                 (write only)
//   0xF8000000-   APF command bridge                          core_bridge_cmd
//
// DATA SLOTS (dist/Cores/frazilpop.Toaplan V2/data.json), in table order:
//
//   [0] id 0  instance JSON (APF requires the instance slot to come first)
//   [1] id 1  <set>.rom at 0x00000000
//   [2] id 2  <set>.sav at 0x20000000, nonvolatile: FixEight's 93C46. The
//             factory contents come with the image (its eeprom region, the
//             set's .nv); APF writes a save over them after the image, both
//             with the core in reset, and reads it back at shutdown.
//   [3] id 330 analogizer.bin at 0xF7000000, from Assets/analogizer/common/
//             (platform index 1), if it is there
//
// The image's 4 KB header says which board and game it is (clocks, work RAM,
// the V25's decryption, the DIP defaults, the graphics sizes); the board
// reads it as it loads, so the instance JSON names the file and nothing else.

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);

// AS4C32M16MSA, 64 MB: 4 banks x 8192 rows x 1024 columns. jtframe_sdram64
// is run as upstream's MiSTer core and the harness run it, AW 22: four 8 MB
// banks, a word address [21:0] each, row = addr[21:9], column =
// {addr[21], addr[8:0]} -- every address on its own cell of the 64 MB part,
// and the bank mapping, the timing and the RTL identical to what was
// simulated against MAME (sim/batsugun/tb_batsugun.sv). The largest region
// any set has, Knuckle Bash's 8 MB of graphics, fills one bank exactly.
localparam AW = 22;

// ============================================================ unused pins
// As Analogue's template leaves them.

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// the cartridge slot is the Analogizer's (pocket_analogizer, after the
// overlay), idle as the template leaves it when there is no adapter

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;

// The PSRAMs and the SRAM are not used: every block RAM the board needs is
// in the FPGA. Held deselected, as the template holds them.
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

// ================================================================= clocks
wire clk_sys, clk_sdram_ps, clk_vid, clk_vid90, clk_anz;
wire pll_core_locked;

mf_pllbase mp1 (
    .refclk   ( clk_74a ),
    .rst      ( 1'b0 ),
    .outclk_0 ( clk_sys ),
    .outclk_1 ( clk_sdram_ps ),
    .outclk_2 ( clk_vid ),
    .outclk_3 ( clk_vid90 ),
    .outclk_4 ( clk_anz ),
    .locked   ( pll_core_locked )
);

// ================================================================= resets
//
// Two, because two things are being reset for different reasons:
//
//   cold_rst    94.5 MHz, PLL lock only: jtframe_sdram64 (which runs its
//               own power-up sequence and must not be reset again), the
//               board's loader and its pixel divider (the board's
//               cold_rst), the shell's loader. APF loads the ROM while it
//               holds the core in reset, so nothing on the loading path may
//               listen to APF's reset.
//   board_rst   94.5 MHz: cold_rst, or APF holding the core in reset (from
//               boot to [0011 Reset Exit], and again from [0010 Reset
//               Enter]), or the Reset action in the menu, or the ROM not
//               yet loaded, or an image whose header the board did not
//               accept. The board adds its own dwnld_busy.

wire pll_core_locked_s;                     // clk_74a
synch_3 s_lock74 (.i(pll_core_locked), .o(pll_core_locked_s), .clk(clk_74a), .rise(), .fall());

wire locked_sys;
synch_3 s_locksys (.i(pll_core_locked), .o(locked_sys), .clk(clk_sys), .rise(), .fall());
reg [7:0] por_cnt = 8'd0;
always @(posedge clk_sys)
    if (!locked_sys)           por_cnt <= 8'd0;
    else if (por_cnt != 8'hff) por_cnt <= por_cnt + 8'd1;
wire cold_rst = (por_cnt != 8'hff);

wire reset_n;                               // clk_74a, from core_bridge_cmd
wire reset_n_sys;
synch_3 s_rstnsys (.i(reset_n), .o(reset_n_sys), .clk(clk_sys), .rise(), .fall());

// ================================================================== bridge
//
// Writes are broadcast: the data_loader inside pocket_rom_loader picks out
// its region, the registers below pick out theirs. Reads are muxed and
// registered.

wire [31:0] cmd_bridge_rd_data;

// ---- settings written by APF (interact.json)
//
// Every field is laid out so that ZERO IS THE DEFAULT: APF writes persisted
// interact values only when there are some, so on a first boot the core's
// reset value IS the setting.
//
//   0xF1000000 [0]     Test Mode: the board's service-mode DIP (DSWA bit 2,
//                      SW1:3 on TP-030 and TP-022, MAME's
//                      TOAPLAN_DSWA_BITS_1_TO_3). Every other DIP stays at
//                      the image header's defaults, which are MAME's.
//                      The game reads the switch at boot, so changing it
//                      resets the game.
//                      FixEight has no DIPs: its settings are in the
//                      EEPROM, set in the test mode, which the board's test
//                      button (SYS bit 2) steps through on each press:
//                      crosshatch, input check, then the menu
//                      (CONFIGURATION, SOUND CHECK), where the game writes
//                      the EEPROM on leaving CONFIGURATION (seen in MAME).
//                      Its attract looks at the button only every few
//                      frames, so a press is held a quarter of a second.
//                      Turned on, Test Mode makes one press, as the menu
//                      closes (the board stands still under it), and while
//                      on, L is the test button; turned off, it resets the
//                      game, the one way out of the test mode.
//   0xF100000C         write: reset the game (1 ms)
//   0xF1000014 [0]     diagnostic overlay (pocket_diag), see DIAGNOSTICS
//   0xF1000018 [1:0]   Screen Rotation, for the vertical games (MAME's
//                      ROT270 sets; Knuckle Bash, ROT0, ignores it): 0
//                      Upright, the picture turned to stand on the Pocket
//                      held as it is; 1 Tate (left), the board's picture as
//                      it is, full width, the Pocket turned a quarter
//                      anticlockwise; 2 Tate (right), the same turned half
//                      round, the Pocket turned a quarter clockwise. The
//                      scaler mode (video, below) and player 1's D-pad
//                      (inputs) both follow it (pocket_rotate). Kept between
//                      sessions (persist), read back for APF.
//
// Both actions are chosen with the Pocket's menu open, while the game is
// paused; a reset is complete long before the menu closes, and the game
// comes up from it as the menu closes.

localparam [31:0] OPT_MENU = 32'h0000_0001;

reg  [31:0] opt_74   = 32'd0;
wire        eeprom_74;                      // the board is FixEight's (below)
wire [31:0] nv_bridge_rd;
reg         diag_74  = 1'b0;
reg  [1:0]  rot_74   = 2'd0;
reg  [16:0] hrst_cnt = 17'd0;               //   1 ms at 74.25 MHz = 74,250
wire        hrst_74  = (hrst_cnt != 17'd0);
wire [31:0] opt_wr   = bridge_wr_data & OPT_MENU;

always @(posedge clk_74a) begin
    if (hrst_cnt != 17'd0) hrst_cnt <= hrst_cnt - 17'd1;
    if (bridge_wr) begin
        case (bridge_addr)
        32'hF1000000: begin
            opt_74 <= opt_wr;
            if (opt_wr[0] != opt_74[0] && !(eeprom_74 && opt_wr[0]))
                hrst_cnt <= 17'd74250;
        end
        32'hF100000C: hrst_cnt <= 17'd74250;
        32'hF1000014: diag_74  <= bridge_wr_data[0];
        32'hF1000018: rot_74   <= bridge_wr_data[1:0];
        default: ;
        endcase
    end
end

always @(posedge clk_74a) begin
    casez (bridge_addr)
    32'hF1000000: bridge_rd_data <= opt_74;
    32'hF1000014: bridge_rd_data <= {31'd0, diag_74};
    32'hF1000018: bridge_rd_data <= {30'd0, rot_74};
    32'h2???????: bridge_rd_data <= nv_bridge_rd;
    32'hF8??????: bridge_rd_data <= cmd_bridge_rd_data;
    default:      bridge_rd_data <= 32'd0;
    endcase
end

// ---- the APF command bridge, as the template wires it
wire            status_boot_done  = pll_core_locked_s;
// "Setup" means ready to take memory writes, which here means the SDRAM has
// finished its power-up sequence.
wire            sdram_init;
wire            mem_ready = ~sdram_init & ~cold_rst;
wire            mem_ready_74;
synch_3 s_memrdy74 (.i(mem_ready), .o(mem_ready_74), .clk(clk_74a), .rise(), .fall());
wire            status_setup_done = pll_core_locked_s & mem_ready_74;
wire            status_running    = reset_n;

wire            dataslot_requestread;
wire    [15:0]  dataslot_requestread_id;
wire            dataslot_requestread_ack = 1;
wire            dataslot_requestread_ok  = 1;

wire            dataslot_requestwrite;
wire    [15:0]  dataslot_requestwrite_id;
wire    [31:0]  dataslot_requestwrite_size;
wire            dataslot_requestwrite_ack = 1;
wire            dataslot_requestwrite_ok  = 1;

wire            dataslot_update;
wire    [15:0]  dataslot_update_id;
wire    [31:0]  dataslot_update_size;

wire            dataslot_allcomplete;

wire     [31:0] rtc_epoch_seconds;
wire     [31:0] rtc_date_bcd;
wire     [31:0] rtc_time_bcd;
wire            rtc_valid;

wire            savestate_supported   = 1'b0;
wire    [31:0]  savestate_addr        = 32'd0;
wire    [31:0]  savestate_size        = 32'd0;
wire    [31:0]  savestate_maxloadsize = 32'd0;

wire            savestate_start;
wire            savestate_start_ack   = 1'b0;
wire            savestate_start_busy  = 1'b0;
wire            savestate_start_ok    = 1'b0;
wire            savestate_start_err   = 1'b0;

wire            savestate_load;
wire            savestate_load_ack    = 1'b0;
wire            savestate_load_busy   = 1'b0;
wire            savestate_load_ok     = 1'b0;
wire            savestate_load_err    = 1'b0;

wire            osnotify_inmenu;

wire            target_dataslot_read      = 1'b0;
wire            target_dataslot_write     = 1'b0;
wire            target_dataslot_getfile   = 1'b0;
wire            target_dataslot_openfile  = 1'b0;

wire            target_dataslot_ack;
wire            target_dataslot_done;
wire    [2:0]   target_dataslot_err;

wire    [15:0]  target_dataslot_id         = 16'd0;
wire    [31:0]  target_dataslot_slotoffset = 32'd0;
wire    [31:0]  target_dataslot_bridgeaddr = 32'd0;
wire    [31:0]  target_dataslot_length     = 32'd0;

wire    [31:0]  target_buffer_param_struct = 32'd0;
wire    [31:0]  target_buffer_resp_struct  = 32'd0;

// THE SAVE FILE'S SIZE (Mille Miglia's). APF writes back as many bytes as
// the Dataslot ID/Size table says, and when no .sav existed yet that entry
// is zero: FixEight would save into its EEPROM and nothing would reach the
// card. So for FixEight the core keeps writing 128 into the save slot's
// size word, table index 2 (data.json order), word 2*2+1. Every other game
// leaves the table alone, and gets no .sav.
wire    [9:0]   datatable_addr = 10'd5;
wire            datatable_wren = eeprom_74;
wire    [31:0]  datatable_data = 32'd128;
wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);

// ===================================================== settings -> 94.5 MHz
wire        opt_test, host_rst, diag_opt;
wire [1:0]  rot_sys;

pocket_sync_bus #(.W(5), .INIT(5'b00000)) s_cfgsys (
    .clk (clk_sys),
    .d   ({rot_74,  opt_74[0], hrst_74,  diag_74}),
    .q   ({rot_sys, opt_test,  host_rst, diag_opt})
);

// DSWA, DSWB, JMPR as the board takes them: XORed into the header's
// defaults (MAME's), so zero leaves every switch at MAME's setting.
wire [31:0] dipsw = {8'd0, 8'd0, 8'd0, 5'd0, opt_test, 2'd0};

wire rom_loaded, cfg_valid;
wire board_rst = cold_rst | ~reset_n_sys | host_rst | ~rom_loaded | ~cfg_valid;

// ================================================================== inputs
//
// The pad bus is on clk_74a. Each button is an independent level, so a
// per-bit synchroniser is enough: a press that lands one cycle earlier on one
// bit than another is invisible to a game polling at 60 Hz.
//
// The board's joysticks are JTFrame's {B3,B2,B1,up,down,left,right}, active
// low (dogyuun_inputs), and key[6:0] is {X,B,A,right,left,down,up}, so the
// D-pad's four bits go in reversed: A is button 1 (shot), B button 2 (bomb),
// X button 3. Select is the coin, Start is start. The picture is turned by
// APF (video.json), not by the board, so Upright needs no turning of the
// D-pad: the game's up is the Pocket's up on the turned picture. In Tate
// (Screen Rotation) the Pocket is held on its side, so player 1's D-pad is
// turned to the game's directions, the Pocket's own controls only
// (cont1_key type 1); player 2 and the Dock's player 3 never turn
// (pocket_rotate).
//
// R (key[9], trig_r1) is rapid shot: button 1 pressed for one frame in four,
// a 15 Hz tap. Batsugun reads its buttons once a frame, on line 257, and in
// MAME a press every fourth frame gives the steadiest stream of shots: on
// alternate frames it fires in bursts with gaps, and slower than one in four
// the stream thins again. The phase steps at the start of vblank (below),
// line 240, so the read comes after the step even when the game's interrupt
// runs late. A wins: button 1 is A or the rapid press, so A and R together
// are the button held. The phase rests at the press while R is up, so R
// fires on the frame it is pressed.
//
// FixEight takes a third player, the dock's controller 3, the same way.
//
// An Analogizer's SNAC controllers (pocket_analogizer) stand in for the
// Pocket's controls of the players analogizer.bin gives them to, as they
// are: their words are in cont_key's order. Nor are they turned: they play
// to the adapter's picture, which is the board's own, never turned.
wire [15:0] key1, key2, key3;
wire        p1_snac;
wire [15:0] k1, k2, k3;
synch_3 #(.WIDTH(16)) s_k1 (.i(key1), .o(k1), .clk(clk_sys), .rise(), .fall());
synch_3 #(.WIDTH(16)) s_k2 (.i(key2), .o(k2), .clk(clk_sys), .rise(), .fall());
synch_3 #(.WIDTH(16)) s_k3 (.i(key3), .o(k3), .clk(clk_sys), .rise(), .fall());
wire       k1_pocket;
synch_3 s_k1_type (.i(cont1_key[31:28] == 4'h1 && !p1_snac), .o(k1_pocket),
                   .clk(clk_sys), .rise(), .fall());

wire [2:0] rot_slot;
wire [3:0] d1;                              //   player 1's D-pad, turned
reg        rot0_q = 1'b0;                   //   the game is ROT0 (video, below)
pocket_rotate u_rotate (
    .rot         (rot_sys),
    .rot0        (rot0_q),
    .pocket_pad  (k1_pocket),
    .dpad        (k1[3:0]),
    .scaler_slot (rot_slot),
    .dpad_game   (d1)
);

reg  [1:0] rapid1   = 2'd0;                 //   the rapid press's phase, 0 pressed
reg  [1:0] rapid2   = 2'd0;
reg  [1:0] rapid3   = 2'd0;
wire [2:0] rapid_b1 = {k3[9] && rapid3 == 2'd0, k2[9] && rapid2 == 2'd0,
                       k1[9] && rapid1 == 2'd0};

wire [6:0] joy1_n  = ~{k1[6:5], k1[4] | rapid_b1[0], d1[0], d1[1], d1[2], d1[3]};
wire [6:0] joy2_n  = ~{k2[6:5], k2[4] | rapid_b1[1], k2[0], k2[1], k2[2], k2[3]};
wire [6:0] joy3_n  = ~{k3[6:5], k3[4] | rapid_b1[2], k3[0], k3[1], k3[2], k3[3]};
wire [3:0] coin_n  = ~{1'b0, k3[14], k2[14], k1[14]};
wire [3:0] start_n = ~{1'b0, k3[15], k2[15], k1[15]};


// Pause: the game is paused while the Pocket's own menu is open (APF's OS
// notify, host command 0x00B0) -- the 68000 halted, the sound held -- and
// the picture behind the menu is blacked out (after the overlay, below).
wire inmenu_sys;
synch_3 s_inmenusys (.i(osnotify_inmenu), .o(inmenu_sys), .clk(clk_sys), .rise(), .fall());

// FixEight's test button (Test Mode, above): one press of a quarter second
// (23,625,000 clocks) once Test Mode is turned on and the menu has closed
// and no reset is running; then L while Test Mode is on.
wire       cfg_eeprom;
reg        opt_test_q = 1'b0;
reg        test_pend  = 1'b0;
reg [24:0] test_cnt   = 25'd0;
always @(posedge clk_sys) begin
    opt_test_q <= opt_test;
    if (!cfg_eeprom || !opt_test)
        test_pend <= 1'b0;
    else if (opt_test && !opt_test_q)
        test_pend <= 1'b1;
    if (test_cnt != 25'd0)
        test_cnt <= test_cnt - 25'd1;
    else if (test_pend && !inmenu_sys && !board_rst) begin
        test_pend <= 1'b0;
        test_cnt  <= 25'd23625000;
    end
end
wire test_n = ~(cfg_eeprom && ((test_cnt != 25'd0) || (opt_test && k1[8])));

// ============================================================ ROM -> board
wire allcomplete_sys;
synch_3 s_allcsys (.i(dataslot_allcomplete), .o(allcomplete_sys), .clk(clk_sys), .rise(), .fall());

wire        ioctl_rom, ioctl_wr;
wire [26:0] ioctl_addr;
wire [7:0]  ioctl_dout;
wire [26:0] ld_bytes;
wire        ld_overflow;
wire        prog_we;

pocket_rom_loader u_loader (
    .clk_74a             (clk_74a),
    .bridge_wr           (bridge_wr),
    .bridge_endian_little(bridge_endian_little),
    .bridge_addr         (bridge_addr),
    .bridge_wr_data      (bridge_wr_data),

    .clk                 (clk_sys),
    .rst                 (cold_rst),
    .allcomplete_s       (allcomplete_sys),

    .ioctl_rom           (ioctl_rom),
    .ioctl_wr            (ioctl_wr),
    .ioctl_addr          (ioctl_addr),
    .ioctl_dout          (ioctl_dout),
    .prog_we             (prog_we),

    .rom_loaded          (rom_loaded),
    .bytes               (ld_bytes),
    .overflow            (ld_overflow)
);

// ================================================================== board
wire [AW-1:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire [3:0]    ba_rd, ba_wr, ba_dst, ba_dok, ba_rdy, ba_ack;
wire [15:0]   ba0_din, ba1_din, ba2_din, ba3_din;
wire [1:0]    ba0_dsn, ba1_dsn, ba2_dsn, ba3_dsn;
wire [15:0]   data_read;
wire [1:0]    prog_ba, prog_mask;
wire          prog_rdy, prog_ack, prog_dok, prog_dst;
wire [15:0]   prog_data;
wire [AW-1:0] prog_addr;
wire          prog_rd;
wire          dwnld_busy;

wire          pxl_cen, LHBL, LVBL, HS, VS;
wire [7:0]    red, green, blue;
wire signed [15:0] snd;
wire          dip_flip;

wire          dbg_loader_error, dbg_v25_run, dbg_v25_fault, dbg_oki_busy;
wire [3:0]    dbg_deadline_miss;
wire [19:0]   dbg_v25_pc;
wire [23:0]   dbg_m68_pc;
wire [31:0]   dbg_m68_rom_rd;
wire          dbg_m68_halted;
wire          cfg_rot0;
wire [5:0]    nv_addr;
wire [15:0]   nv_din, nv_dout;
wire          nv_we, nv_dirty, nv_dirty_clr;

dogyuun_game #(.AW(AW)) u_game (
    .rst        (board_rst),
    .cold_rst   (cold_rst),
    .clk        (clk_sys),
    .clk96      (clk_sys),  .rst96 (board_rst),
    .clk48      (clk_sys),  .rst48 (board_rst),
    .clk24      (clk_sys),  .rst24 (board_rst),
    .pxl2_cen   (),
    .pxl_cen    (pxl_cen),
    .red        (red),
    .green      (green),
    .blue       (blue),
    .LHBL       (LHBL),
    .LVBL       (LVBL),
    .HS         (HS),
    .VS         (VS),
    .cab_1p     (start_n),
    .coin       (coin_n),
    .joystick1  (joy1_n),
    .joystick2  (joy2_n),
    .joystick3  (joy3_n),
    .joystick4  (7'h7f),
    .joyana_l1  (16'd0), .joyana_l2 (16'd0), .joyana_l3 (16'd0), .joyana_l4 (16'd0),
    .joyana_r1  (16'd0), .joyana_r2 (16'd0), .joyana_r3 (16'd0), .joyana_r4 (16'd0),
    .dial_x     (2'd0),
    .dial_y     (2'd0),
    .ioctl_addr (ioctl_addr),
    .ioctl_dout (ioctl_dout),
    .ioctl_cart (1'b0),
    .ioctl_wr   (ioctl_wr),
    .ioctl_ram  (1'b0),
    .ioctl_din  (),
    .ioctl_rom  (ioctl_rom),
    .dwnld_busy (dwnld_busy),
    .data_read  (data_read),
    .ba0_addr   (ba0_addr), .ba1_addr (ba1_addr), .ba2_addr (ba2_addr), .ba3_addr (ba3_addr),
    .ba_rd      (ba_rd),
    .ba_wr      (ba_wr),
    .ba_dst     (ba_dst),
    .ba_dok     (ba_dok),
    .ba_rdy     (ba_rdy),
    .ba_ack     (ba_ack),
    .ba0_din    (ba0_din), .ba0_dsn (ba0_dsn),
    .ba1_din    (ba1_din), .ba1_dsn (ba1_dsn),
    .ba2_din    (ba2_din), .ba2_dsn (ba2_dsn),
    .ba3_din    (ba3_din), .ba3_dsn (ba3_dsn),
    .prog_ba    (prog_ba),
    .prog_rdy   (prog_rdy),
    .prog_ack   (prog_ack),
    .prog_dok   (prog_dok),
    .prog_dst   (prog_dst),
    .prog_data  (prog_data),
    .prog_addr  (prog_addr),
    .prog_rd    (prog_rd),
    .prog_we    (prog_we),
    .prog_mask  (prog_mask),
    .status     (32'd0),
    .dip_pause  (~inmenu_sys),
    .dip_flip   (dip_flip),
    .dip_test   (test_n),           // FixEight's test button; elsewhere Test Mode is the DIP
    .dip_fxlevel(2'd0),
    .service    (1'b1),             // no service coin: Select is the coin
    .tilt       (1'b1),
    .dipsw      (dipsw),
    .snd_left   (snd),
    .snd_right  (),
    .sample     (),
    .snd_en     (6'h3f),
    .snd_vol    (8'hff),
    .snd_vu     (),
    .snd_peak   (),
    .gfx_en     (4'hf),

    .dbg_cfg_valid    (cfg_valid),
    .dbg_loader_error (dbg_loader_error),
    .dbg_v25_run      (dbg_v25_run),
    .dbg_v25_fault    (dbg_v25_fault),
    .dbg_deadline_miss(dbg_deadline_miss),
    .dbg_oki_busy     (dbg_oki_busy),
    .dbg_v25_pc       (dbg_v25_pc),
    .dbg_m68_pc       (dbg_m68_pc),
    .dbg_m68_rom_rd   (dbg_m68_rom_rd),
    .dbg_m68_halted   (dbg_m68_halted),
    .cfg_rot0         (cfg_rot0),
    .cfg_eeprom       (cfg_eeprom),

    .nv_addr          (nv_addr),
    .nv_din           (nv_din),
    .nv_we            (nv_we),
    .nv_dout          (nv_dout),
    .nv_dirty         (nv_dirty),
    .nv_dirty_clr     (nv_dirty_clr)
);

// ================================================================= EEPROM
pocket_nvram u_nvram (
    .clk_74a             (clk_74a),
    .bridge_wr           (bridge_wr),
    .bridge_rd           (bridge_rd),
    .bridge_endian_little(bridge_endian_little),
    .bridge_addr         (bridge_addr),
    .bridge_wr_data      (bridge_wr_data),
    .bridge_rd_word      (nv_bridge_rd),
    .clk                 (clk_sys),
    .nv_addr             (nv_addr),
    .nv_din              (nv_din),
    .nv_we               (nv_we),
    .nv_dout             (nv_dout),
    .nv_dirty            (nv_dirty),
    .nv_dirty_clr        (nv_dirty_clr)
);

// Which board the image is, for the bridge side: static once loaded.
synch_3 s_eep74 (.i(cfg_eeprom), .o(eeprom_74), .clk(clk_74a), .rise(), .fall());

// ================================================================== SDRAM
//
// jtframe_sdram64 as upstream's MiSTer core sets it at 94.5 MHz and as the
// harness ran it against MAME: HF, not shifted, 64-bit bursts on all four
// banks, bank 0 auto-precharge, the programming port in 32-bit bursts,
// MISTER 0 (separate DQM pins), a refresh burst every 1536 clocks. Two
// Pocket differences, both at the pins:
//
//   - The Pocket's SDRAM has no CS# pin (it is tied active on the board).
//     jtframe_sdram64 never deselects in operation (CMD_INHIBIT is unused),
//     so dropping sdram_ncs loses nothing.
//   - dram_clk is clk_sdram_ps (180 degrees) forwarded through a DDIO output
//     register, as Mille Miglia's shell forwards its own, and as upstream's
//     MiSTer top forwards SDRAM_CLK (at -171 degrees). With CL 2 the first
//     word is sampled three clk_sys edges after the READ leaves its
//     register, the edge the Pocket's part was measured to want with the
//     same forwarding (the harness's model drives it on that edge).

reg [10:0] rfsh_cnt = 11'd0;
wire       rfsh = (rfsh_cnt == 11'd0);
always @(posedge clk_sys) rfsh_cnt <= (rfsh_cnt == 11'd1535) ? 11'd0 : rfsh_cnt + 11'd1;

wire sdram_ncs_unused, sdram_dqml, sdram_dqmh;
assign dram_dqm = {sdram_dqmh, sdram_dqml};

jtframe_sdram64 #(
    .AW           (AW),
    .HF           (1),
    .SHIFTED      (0),
    .BA0_LEN      (64),
    .BA1_LEN      (64),
    .BA2_LEN      (64),
    .BA3_LEN      (64),
    .PROG_LEN     (32),
    .BA0_AUTOPRECH(1),
    .MISTER       (0)
) u_sdram (
    .rst        (cold_rst),
    .clk        (clk_sys),
    .init       (sdram_init),
    .ba0_addr   (ba0_addr), .ba1_addr (ba1_addr), .ba2_addr (ba2_addr), .ba3_addr (ba3_addr),
    .rd         (ba_rd),
    .wr         (ba_wr),
    .ba0_din    (ba0_din), .ba0_dsn (ba0_dsn),
    .ba1_din    (ba1_din), .ba1_dsn (ba1_dsn),
    .ba2_din    (ba2_din), .ba2_dsn (ba2_dsn),
    .ba3_din    (ba3_din), .ba3_dsn (ba3_dsn),
    .prog_en    (dwnld_busy),
    .prog_addr  (prog_addr),
    .prog_rd    (prog_rd),
    .prog_wr    (prog_we),
    .prog_din   (prog_data),
    .prog_dsn   (prog_mask),
    .prog_ba    (prog_ba),
    .prog_dst   (prog_dst),
    .prog_dok   (prog_dok),
    .prog_rdy   (prog_rdy),
    .prog_ack   (prog_ack),
    .rfsh       (rfsh),
    .ack        (ba_ack),
    .dst        (ba_dst),
    .dok        (ba_dok),
    .rdy        (ba_rdy),
    .dout       (data_read),
    .sdram_dq   (dram_dq),
    .sdram_a    (dram_a),
    .sdram_dqml (sdram_dqml),
    .sdram_dqmh (sdram_dqmh),
    .sdram_ba   (dram_ba),
    .sdram_nwe  (dram_we_n),
    .sdram_ncas (dram_cas_n),
    .sdram_nras (dram_ras_n),
    .sdram_ncs  (sdram_ncs_unused),
    .sdram_cke  (dram_cke)
);

pin_ddio_clk u_dram_clk (
    .datain_h ( 1'b1 ),
    .datain_l ( 1'b0 ),
    .outclock ( clk_sdram_ps ),
    .dataout  ( dram_clk )
);

// ========================================================= video timing
//
// The board's raster is held in reset with the game, and gives no sync
// then. While it is, the shell draws the same raster itself (432 x 262 on
// the board's pixel enable, 320 x 240 visible, the board's sync positions),
// so APF always has a picture: the overlay over colour bars until the game
// runs. The board's HS/VS are active low, LHBL/LVBL high in the picture.
reg [8:0] fb_h = 9'd0;
reg [8:0] fb_v = 9'd0;
always @(posedge clk_sys) if (pxl_cen) begin
    if (fb_h == 9'd431) begin
        fb_h <= 9'd0;
        fb_v <= (fb_v == 9'd261) ? 9'd0 : fb_v + 9'd1;
    end else
        fb_h <= fb_h + 9'd1;
end

reg  vid_hs, vid_vs, vid_hblank, vid_vblank;
reg  [7:0] vid_r, vid_g, vid_b;
always @(posedge clk_sys) if (pxl_cen) begin
    // One pixel behind the board's own registers, the fallback likewise.
    if (board_rst) begin
        vid_hblank <= fb_h >= 9'd320;
        vid_vblank <= fb_v >= 9'd240;
        vid_hs     <= (fb_h >= 9'd340) && (fb_h < 9'd376);
        vid_vs     <= (fb_v >= 9'd244) && (fb_v < 9'd248);
        {vid_r, vid_g, vid_b} <= 24'd0;
    end else begin
        vid_hblank <= ~LHBL;
        vid_vblank <= ~LVBL;
        vid_hs     <= ~HS;
        vid_vs     <= ~VS;
        {vid_r, vid_g, vid_b} <= {red, green, blue};
    end
end

// ============================================================ DIAGNOSTICS
//
// pocket_diag draws the shell's state over the picture (its header says
// what, where). It is on whenever the menu's "Diagnostic overlay" is, and on
// its own while the board is held in reset (the ROM not loaded, or an image
// it did not accept), when colour bars stand in for the picture: a core that
// never gets past loading says so on screen instead of staying black.
//
// Flags (left to right, green = 1):
//   0 PLL locked            1 SDRAM initialised
//   2 APF reset released    3 APF "all slots loaded" seen
//   4 rom_loaded            5 the loader's byte FIFO overflowed (should stay red)
//   6 the image header accepted (magic TPV2)
//   7 the board's loader saw a byte outside every region (should stay red)
//   8 board in reset        9 the V25 released by the 68000
//   10 the V25 faulted (an opcode the z8086 does not have; should stay red)
//   11 a line engine missed its line: SDRAM too slow for the video (red)
//   12 an OKI channel playing (live)
//   13 the 68000 halted (a double bus fault; should stay red)
//   14 blinks about once a second (frame counter)
//   15 the 68000's first fetch (its reset vectors, SDRAM bank 0 words 0-3)
//      read back equal to what the loader wrote: the SDRAM read path right
//
// Counters (hex):
//   0 longest wait for a read, request to ready, in 94.5 MHz clocks: high
//     half bank 1 (GP9001 #0 graphics), low half bank 0 (68000 program)
//   1 the same, high half bank 3 (OKI samples), low half bank 2 (GP9001 #1)
//   2 line engines' deadline misses, a byte each (saturating), the board's
//     dbg_deadline_miss bits 3..0 from the left
//   3 the V25's PC, live (a hung V25 shows one address)
//   4 frames since the board left reset
//   5 bytes of the image taken by the board's loader (the .rom's length
//     when loaded: 006C1000 for TP-030 and TP-022)
//   6 the 68000's last program fetch, live: where it is (a STOP shows one
//     address)
//   7 the 68000's last data read from the ROM, {address, byte}: a table or
//     string it read, or how far an upload from the ROM has got
//
// Peaks and flags 3, 11 hold until the overlay is turned OFF in the menu
// (diag_clr), so the routine is: overlay on to see the baseline, off to
// clear, play until the moment, overlay on and photograph.
wire mem_ready_sys = mem_ready;

reg         diag_opt_q = 1'b0;
wire        diag_clr = diag_opt_q & ~diag_opt;    // overlay turned off
reg  [15:0] w_cnt [0:3];
reg  [15:0] w_max [0:3];
reg  [7:0]  miss  [0:3];
reg         f_allc = 1'b0, f_miss = 1'b0;
reg         vb_q = 1'b0;
reg  [7:0]  frame = 8'd0;
reg  [31:0] frames = 32'd0;
reg  [15:0] exp_w [0:3];
reg  [15:0] rb_w  [0:3];
reg  [2:0]  rb_i  = 3'd4;                         // 4: not capturing
reg         rb_armed = 1'b0;
integer     j;

// Rapid shot's phase (inputs, above): stepped at the start of vblank.
always @(posedge clk_sys) begin
    if (vid_vblank && !vb_q) begin
        rapid1 <= rapid1 + 2'd1;
        rapid2 <= rapid2 + 2'd1;
        rapid3 <= rapid3 + 2'd1;
    end
    if (!k1[9]) rapid1 <= 2'd0;
    if (!k2[9]) rapid2 <= 2'd0;
    if (!k3[9]) rapid3 <= 2'd0;
end

always @(posedge clk_sys) begin
    diag_opt_q <= diag_opt;
    // Request-to-ready on each bank: a request is a level, held until the
    // controller says the data are there.
    for (j = 0; j < 4; j = j + 1) begin
        if (!ba_rd[j] || ba_rdy[j]) w_cnt[j] <= 16'd0;
        else if (w_cnt[j] != 16'hffff) w_cnt[j] <= w_cnt[j] + 16'd1;
    end
    if (board_rst || diag_clr) begin
        for (j = 0; j < 4; j = j + 1) begin
            w_max[j] <= 16'd0;
            miss[j]  <= 8'd0;
        end
        f_miss <= 1'b0;
        if (diag_clr) f_allc <= 1'b0;
    end else begin
        for (j = 0; j < 4; j = j + 1) begin
            if (w_cnt[j] > w_max[j]) w_max[j] <= w_cnt[j];
            if (dbg_deadline_miss[j] && miss[j] != 8'hff) miss[j] <= miss[j] + 8'd1;
        end
        if (|dbg_deadline_miss) f_miss <= 1'b1;
    end
    if (allcomplete_sys) f_allc <= 1'b1;

    vb_q <= vid_vblank;
    if (pxl_cen && vid_vblank && !vb_q) frame <= frame + 8'd1;
    if (board_rst) frames <= 32'd0;
    else if (vid_vblank && !vb_q) frames <= frames + 32'd1;

    // What the loader wrote to bank 0 words 0-3, and what the first bank 0
    // read after the board leaves reset (the 68000's vector fetch, one
    // 64-bit burst) brings back: dst marks word 0, the next three follow.
    if (prog_we && prog_ack && prog_ba == 2'd0 && prog_addr[AW-1:2] == {(AW-2){1'b0}})
        exp_w[prog_addr[1:0]] <= prog_data;
    if (board_rst) begin
        rb_armed <= 1'b1;
        rb_i     <= 3'd4;
    end else if (rb_armed && ba_dst[0]) begin
        rb_w[0]  <= data_read;
        rb_i     <= 3'd1;
        rb_armed <= 1'b0;
    end else if (rb_i != 3'd4) begin
        rb_w[rb_i[1:0]] <= data_read;
        rb_i <= rb_i + 3'd1;
    end
end

wire rb_good = !rb_armed && rb_i == 3'd4 &&
               rb_w[0] == exp_w[0] && rb_w[1] == exp_w[1] &&
               rb_w[2] == exp_w[2] && rb_w[3] == exp_w[3];

// Registered, so that nothing on the board (the V25's PC is computed from
// its prefetch queue) reaches the overlay's text and the video register in
// the same clock. The overlay shows each value a clock late.
reg  [15:0]  diag_flags = 16'd0;
reg  [255:0] diag_cnt   = 256'd0;
always @(posedge clk_sys) begin
    diag_flags <= {rb_good, frame[5], dbg_m68_halted, dbg_oki_busy, f_miss,
                   dbg_v25_fault, dbg_v25_run, board_rst,
                   dbg_loader_error, cfg_valid, ld_overflow, rom_loaded,
                   f_allc, reset_n_sys, mem_ready_sys, locked_sys};
    diag_cnt   <= {dbg_m68_rom_rd,
                   8'd0, dbg_m68_pc,
                   5'd0, ld_bytes,
                   frames,
                   12'd0, dbg_v25_pc,
                   miss[3], miss[2], miss[1], miss[0],
                   w_max[3], w_max[2], w_max[1], w_max[0]};
end
wire [7:0]  dr, dg, db;
pocket_diag u_diag (
    .clk    (clk_sys),
    .ce_pix (pxl_cen),
    .hblank (vid_hblank),
    .vblank (vid_vblank),
    .r_in   (vid_r), .g_in (vid_g), .b_in (vid_b),
    .enable (diag_opt | board_rst),
    .bars   (board_rst),
    .flags  (diag_flags),
    .cnt    (diag_cnt),
    .r_out  (dr), .g_out (dg), .b_out (db)
);

// Black behind the Pocket's menu: the game is paused under it.
wire [7:0] mr = inmenu_sys ? 8'd0 : dr;
wire [7:0] mg = inmenu_sys ? 8'd0 : dg;
wire [7:0] mb = inmenu_sys ? 8'd0 : db;

// ============================================================= Analogizer
//
// The board's raster, as the Pocket's screen gets it (the overlay in, black
// under the menu, the syncs running on), out of the cartridge slot; and
// SNAC controllers in (inputs, above). pocket_analogizer says how it is set.
// The picture is the board's unturned: the vertical games want the monitor
// on its side, as in the arcade, and Screen Rotation turns only the Pocket's
// screen.
wire anz_pocket_off;
pocket_analogizer u_analogizer (
    .clk_74a        (clk_74a),
    .bridge_wr      (bridge_wr),
    .bridge_addr    (bridge_addr),
    .bridge_wr_data (bridge_wr_data),
    .clk_sys        (clk_sys),
    .ce_pix         (pxl_cen),
    .hs             (vid_hs),     .vs     (vid_vs),
    .hblank         (vid_hblank), .vblank (vid_vblank),
    .r              (mr),         .g      (mg),       .b  (mb),
    .pocket_off     (anz_pocket_off),
    .clk_anz        (clk_anz),
    .cont1_key      (cont1_key[15:0]), .cont2_key (cont2_key[15:0]),
    .cont3_key      (cont3_key[15:0]),
    .key1           (key1),       .key2   (key2),     .key3 (key3),
    .p1_snac        (p1_snac),
    .cart_tran_bank2 (cart_tran_bank2), .cart_tran_bank2_dir (cart_tran_bank2_dir),
    .cart_tran_bank3 (cart_tran_bank3), .cart_tran_bank3_dir (cart_tran_bank3_dir),
    .cart_tran_bank1 (cart_tran_bank1), .cart_tran_bank1_dir (cart_tran_bank1_dir),
    .cart_tran_bank0 (cart_tran_bank0), .cart_tran_bank0_dir (cart_tran_bank0_dir),
    .cart_tran_pin30 (cart_tran_pin30), .cart_tran_pin30_dir (cart_tran_pin30_dir),
    .cart_pin30_pwroff_reset (cart_pin30_pwroff_reset),
    .cart_tran_pin31 (cart_tran_pin31), .cart_tran_pin31_dir (cart_tran_pin31_dir)
);

// the Pocket's own screen black when analogizer.bin asks for it
wire [7:0] pr = anz_pocket_off ? 8'd0 : mr;
wire [7:0] pg = anz_pocket_off ? 8'd0 : mg;
wire [7:0] pb = anz_pocket_off ? 8'd0 : mb;

// ================================================================== video
assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid90;

// The game's rotation, from the image header: video.json's scaler mode 1
// for ROT0, 0 for ROT270, and for the vertical games Screen Rotation's 1
// (Tate (left), the picture as it is) or 2 (Tate (right), turned 180)
// (pocket_rotate, inputs above). Registered here; it changes only on a load.
always @(posedge clk_sys) rot0_q <= cfg_rot0;

pocket_video u_video (
    .clk       (clk_sys),
    .ce_pix    (pxl_cen),
    .hs        (vid_hs),
    .vs        (vid_vs),
    .hblank    (vid_hblank),
    .vblank    (vid_vblank),
    .r         (pr),
    .g         (pg),
    .b         (pb),
    .scaler_slot (rot_slot),
    .clk_vid   (clk_vid),
    .video_rgb (video_rgb),
    .video_de  (video_de),
    .video_hs  (video_hs),
    .video_vs  (video_vs),
    .video_skip(video_skip)
);

// ================================================================== audio
//
// The board's mono mix to both channels. sound_i2s (agg23, MIT) generates
// MCLK/SCLK/LRCK from clk_74a as Analogue's example does and moves each new
// sample across from the board clock through a small dcfifo.
sound_i2s #(
    .CHANNEL_WIDTH(16),
    .SIGNED_INPUT (1)
) u_i2s (
    .clk_74a   (clk_74a),
    .clk_audio (clk_sys),
    .audio_l   (snd),
    .audio_r   (snd),
    .audio_mclk(audio_mclk),
    .audio_lrck(audio_lrck),
    .audio_dac (audio_dac)
);

endmodule

`default_nettype wire

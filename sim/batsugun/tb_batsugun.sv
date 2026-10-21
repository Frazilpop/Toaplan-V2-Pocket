// SPDX-License-Identifier: GPL-3.0-or-later
// Toaplan V2 (Pocket) - the board-level Verilator harness's top.
//
// The two-GP9001 board (dogyuun_game) with the SDRAM controller the Pocket
// shell uses (jtframe_sdram64, set as upstream's MiSTer core sets it at
// 94.5 MHz: HF, not shifted, 64-bit bursts, bank 0 auto-precharge, a
// refresh burst every 1536 clocks), its pins out to tb_batsugun.cpp's SDRAM
// model. One clock, 94.5 MHz; the board's other clock inputs are unused.
//
// The taps below bring out the 68000's and the V25's buses for the traces
// compared against MAME.
module tb_batsugun (
    input              clk,
    input              rst,         // the game (68000, V25, raster)
    input              cold_rst,    // the loader and the SDRAM controller

    input              ioctl_rom,
    input      [26:0]  ioctl_addr,
    input      [7:0]   ioctl_dout,
    input              ioctl_wr,
    output             dwnld_busy,

    input      [6:0]   joy1_n,      // {B3,B2,B1,U,D,L,R}, active low
    input      [6:0]   joy2_n,
    input      [3:0]   start_n,
    input      [3:0]   coin_n,
    input              service_n,
    input              test_n,
    input              pause_n,
    input      [31:0]  dipsw,

    output     [7:0]   red,
    output     [7:0]   green,
    output     [7:0]   blue,
    output             LHBL,
    output             LVBL,
    output             pxl_cen,
    output signed [15:0] snd,
    output             sample,

    // SDRAM pins
    output     [12:0]  sdram_a,
    output     [1:0]   sdram_ba,
    output             sdram_ncs,
    output             sdram_nras,
    output             sdram_ncas,
    output             sdram_nwe,
    output             sdram_cke,
    output     [1:0]   sdram_dqm,
    output     [15:0]  sdram_din,
    input      [15:0]  sdram_dq,
    output             sdram_init,

    // 68000 bus
    output     [23:0]  m68_addr,
    output             m68_as_n,
    output             m68_rw,
    output             m68_uds_n,
    output             m68_lds_n,
    output             m68_dtack_n,
    output     [15:0]  m68_din,
    output     [15:0]  m68_dout,
    output             m68_iack,
    // V25 bus and state
    output     [19:0]  v25_addr,
    output             v25_mem_active,
    output             v25_r_w,
    output     [7:0]   v25_dout,
    output     [7:0]   v25_din,
    output             v25_reset_n,
    output     [19:0]  v25_pc,
    output             v25_fault,
    output             v25_sfr_read,   // an internal read completes: SFR at v25_sfr_index
    output     [8:0]   v25_sfr_index,
    output     [7:0]   v25_sfr_data,
    // loader
    output             ld_cfg_valid,
    output             ld_prog_we,
    output             ld_range_error,
    output             ld_overflow_error,
    output     [3:0]   video_miss,
    output     [15:0]  m68_missing,
    output             vid_line_ready,
    output     [10:0]  vid_color,
    output     [15:0]  vid_palette,
    output     [3:0]   dbg_ba_rd,
    output     [3:0]   dbg_ba_ack,
    output     [3:0]   dbg_ba_rdy,
    output     [3:0]   dbg_engine_busy,
    output     [3:0]   dbg_line_valid
);

localparam AW = 22;

wire [AW-1:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire [3:0]    ba_rd, ba_wr, ba_dst, ba_dok, ba_rdy, ba_ack;
wire [15:0]   ba0_din, ba1_din, ba2_din, ba3_din;
wire [1:0]    ba0_dsn, ba1_dsn, ba2_dsn, ba3_dsn;
wire [15:0]   data_read;
wire [1:0]    prog_ba, prog_mask;
wire          prog_rdy, prog_ack, prog_dok, prog_dst;
wire [15:0]   prog_data;
wire [AW-1:0] prog_addr;
wire          prog_rd, prog_we;
wire          dip_flip;

dogyuun_game #(.AW(AW)) u_game (
    .rst        (rst),
    .cold_rst   (cold_rst),
    .clk        (clk),
    .clk96      (clk),  .rst96 (rst),
    .clk48      (clk),  .rst48 (rst),
    .clk24      (clk),  .rst24 (rst),
    .pxl2_cen   (),
    .pxl_cen    (pxl_cen),
    .red        (red),
    .green      (green),
    .blue       (blue),
    .LHBL       (LHBL),
    .LVBL       (LVBL),
    .HS         (),
    .VS         (),
    .cab_1p     (start_n),
    .coin       (coin_n),
    .joystick1  (joy1_n),
    .joystick2  (joy2_n),
    .joystick3  (7'h7f),
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
    .dip_pause  (pause_n),
    .dip_flip   (dip_flip),
    .dip_test   (test_n),
    .dip_fxlevel(2'd0),
    .service    (service_n),
    .tilt       (1'b1),
    .dipsw      (dipsw),
    .snd_left   (snd),
    .snd_right  (),
    .sample     (sample),
    .snd_en     (6'h3f),
    .snd_vol    (8'hff),
    .snd_vu     (),
    .snd_peak   (),
    .gfx_en     (4'hf)
);

// One refresh burst every 1536 clocks (upstream's JTFRAME_RFSH_N/M).
reg [10:0] rfsh_cnt = 11'd0;
wire       rfsh = rfsh_cnt == 11'd0;
always @(posedge clk) rfsh_cnt <= (rfsh_cnt == 11'd1535) ? 11'd0 : rfsh_cnt + 11'd1;

wire sdram_dqml, sdram_dqmh;
// jtframe_sdram64 only reads its inout DQ under Verilator; the model drives it.
wire [15:0] sdram_dq_w = sdram_dq;
assign sdram_dqm = {sdram_dqmh, sdram_dqml};

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
    .clk        (clk),
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
    .sdram_dq   (sdram_dq_w),
    .sdram_din  (sdram_din),
    .sdram_a    (sdram_a),
    .sdram_dqml (sdram_dqml),
    .sdram_dqmh (sdram_dqmh),
    .sdram_ba   (sdram_ba),
    .sdram_nwe  (sdram_nwe),
    .sdram_ncas (sdram_ncas),
    .sdram_nras (sdram_nras),
    .sdram_ncs  (sdram_ncs),
    .sdram_cke  (sdram_cke)
);

// Taps
assign m68_addr    = u_game.u_main.cpu_addr8;
assign m68_as_n    = u_game.u_main.cpu_as_n;
assign m68_rw      = u_game.u_main.cpu_rw;
assign m68_uds_n   = u_game.u_main.cpu_uds_n;
assign m68_lds_n   = u_game.u_main.cpu_lds_n;
assign m68_dtack_n = u_game.u_main.cpu_dtack_n;
assign m68_din     = u_game.u_main.cpu_din;
assign m68_dout    = u_game.u_main.cpu_dout;
assign m68_iack    = u_game.u_main.cpu_iack;

assign v25_addr       = u_game.u_sound.v25_bus_addr;
assign v25_mem_active = u_game.u_sound.v25_mem_active;
assign v25_r_w        = u_game.u_sound.v25_bus_r_w;
assign v25_dout       = u_game.u_sound.v25_bus_dout;
assign v25_din        = u_game.u_sound.v25_bus_din;
assign v25_reset_n    = u_game.u_sound.v25_reset_n;
assign v25_pc         = u_game.u_sound.debug_pc;
assign v25_fault      = u_game.u_sound.debug_fault;

wire [8:0] sfr_i = u_game.u_sound.u_v25.int_index0;
assign v25_sfr_read  = u_game.u_sound.u_v25.bus_state == 4'd1 &&
                       u_game.u_sound.u_v25.int_done &&
                       u_game.u_sound.u_v25.bus_phase_advance &&
                       !u_game.u_sound.u_v25.txn_write && sfr_i[8];
assign v25_sfr_index = sfr_i;
assign v25_sfr_data  = u_game.u_sound.u_v25.internal_read_byte(sfr_i, 8'h00);
assign ld_cfg_valid      = u_game.cfg_valid;
assign ld_prog_we        = u_game.prog_we;
assign ld_range_error    = u_game.loader_range_error;
assign ld_overflow_error = u_game.loader_overflow_error;
assign video_miss        = u_game.video_deadline_miss;
assign m68_missing       = u_game.u_main.u_cpu_cen.missing;
assign vid_line_ready    = u_game.video_line_ready;
assign dbg_ba_rd = ba_rd;
assign dbg_ba_ack = ba_ack;
assign dbg_ba_rdy = ba_rdy;
assign dbg_engine_busy = u_game.video_engine_busy;
assign dbg_line_valid = u_game.video_debug_line_valid;
assign vid_color         = u_game.video_palette_addr;
assign vid_palette       = u_game.video_palette_data;

endmodule

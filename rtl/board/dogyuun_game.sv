// Toaplan V2 board with the V25 (TP-030 Batsugun, TP-022 Dogyuun, TP-023
// Knuckle Bash, TP-026 FixEight, TP-027 Grind Stormer / V-Five): ROM image
// loading,
// board-accurate raster, MC68000, V25/audio subsystem, and the dual-GP9001
// line renderer (the second chip idle on a one-chip board). What differs
// between the boards comes from the image header (dogyuun_rom_loader's
// cfg_*): clocks, work RAM, the 68000's and V25's maps, the V25's opcode
// decryption (nitro, or none), its DIP ports, the OKI's rate, the graphics
// region sizes and the GP mix. dipsw is XORed into the header's DIP
// defaults (0: MAME's). TP-026 adds the text layer over the GP9001, a third
// player and the 93C46 EEPROM, whose 64 words the platform seeds and saves
// through nv_* (the board in reset).
module dogyuun_game #(
    parameter integer AW = 22
) (
    input              rst,
    input              cold_rst,
    input              clk,
    input              clk96,
    input              rst96,
    input              clk48,
    input              rst48,
    input              clk24,
    input              rst24,

    output reg         pxl2_cen,
    output reg         pxl_cen,
    output reg [7:0]   red,
    output reg [7:0]   green,
    output reg [7:0]   blue,
    output reg         LHBL,
    output reg         LVBL,
    output reg         HS,
    output reg         VS,

    input      [3:0]   cab_1p,
    input      [3:0]   coin,
    input      [`JTFRAME_BUTTONS+3:0] joystick1,
    input      [`JTFRAME_BUTTONS+3:0] joystick2,
    input      [`JTFRAME_BUTTONS+3:0] joystick3,
    input      [`JTFRAME_BUTTONS+3:0] joystick4,
    input      [15:0]  joyana_l1,
    input      [15:0]  joyana_l2,
    input      [15:0]  joyana_l3,
    input      [15:0]  joyana_l4,
    input      [15:0]  joyana_r1,
    input      [15:0]  joyana_r2,
    input      [15:0]  joyana_r3,
    input      [15:0]  joyana_r4,
    input      [1:0]   dial_x,
    input      [1:0]   dial_y,

    input      [26:0]  ioctl_addr,
    input      [7:0]   ioctl_dout,
    input              ioctl_cart,
    input              ioctl_wr,
    input              ioctl_ram,
    output     [7:0]   ioctl_din,
    input              ioctl_rom,
    output             dwnld_busy,
    input      [15:0]  data_read,

    output     [AW-1:0] ba0_addr,
    output     [AW-1:0] ba1_addr,
    output     [AW-1:0] ba2_addr,
    output     [AW-1:0] ba3_addr,
    output     [3:0]   ba_rd,
    output     [3:0]   ba_wr,
    input      [3:0]   ba_dst,
    input      [3:0]   ba_dok,
    input      [3:0]   ba_rdy,
    input      [3:0]   ba_ack,
    output     [15:0]  ba0_din,
    output     [1:0]   ba0_dsn,
    output     [15:0]  ba1_din,
    output     [1:0]   ba1_dsn,
    output     [15:0]  ba2_din,
    output     [1:0]   ba2_dsn,
    output     [15:0]  ba3_din,
    output     [1:0]   ba3_dsn,

    output     [1:0]   prog_ba,
    input              prog_rdy,
    input              prog_ack,
    input              prog_dok,
    input              prog_dst,
    output     [15:0]  prog_data,
    output     [AW-1:0] prog_addr,
    output             prog_rd,
    output             prog_we,
    output     [1:0]   prog_mask,

    input      [31:0]  status,
    input              dip_pause,
    inout              dip_flip,
    input              dip_test,
    input      [1:0]   dip_fxlevel,
    input              service,
    input              tilt,
    input      [31:0]  dipsw,

    output signed [15:0] snd_left,
    output signed [15:0] snd_right,
    output             sample,
    input      [5:0]   snd_en,
    input      [7:0]   snd_vol,
    output     [5:0]   snd_vu,
    output             snd_peak,

    input      [3:0]   gfx_en,

    // The Pocket shell's diagnostic overlay
    output             dbg_cfg_valid,      // the image header read, magic good
    output             dbg_loader_error,   // a byte outside every region, or overrun
    output             dbg_v25_run,        // the V25 out of reset
    output             dbg_v25_fault,
    output     [3:0]   dbg_deadline_miss,  // a line engine missed its line (pulses)
    output             dbg_oki_busy,       // an OKI channel playing
    output     [19:0]  dbg_v25_pc,
    output     [23:0]  dbg_m68_pc,         // the 68000's last program fetch
    output     [31:0]  dbg_m68_rom_rd,     // its last data read from ROM: {address, byte}
    output             dbg_m68_halted,
    output             cfg_rot0,           // the game is ROT0 (Knuckle Bash)
    output             cfg_eeprom,         // the board has the 93C46 (TP-026)

    // The 93C46's words for the save slot (pocket_nvram): read one clock
    // after the address, written with the board in reset.
    input      [5:0]   nv_addr,
    input      [15:0]  nv_din,
    input              nv_we,
    output     [15:0]  nv_dout,
    output             nv_dirty,
    input              nv_dirty_clr
);

localparam [9:0] H_TOTAL = 10'd432;
localparam [8:0] V_TOTAL = 9'd262;

reg [3:0] clkdiv;
reg [9:0] hcnt;
reg [8:0] vcnt;
reg       video_epoch;
wire loader_accepted;
wire loader_range_error;
wire loader_overflow_error;
wire [26:0] loader_last_addr;
wire        cfg_valid;
wire [2:0]  cfg_board;
wire        cfg_two_gp;
wire [1:0]  cfg_table;
wire        cfg_oki_pin7;
wire        cfg_wram_64k;
wire [6:0]  cfg_cpu_num;
wire [6:0]  cfg_v25_num;
wire [4:0]  cfg_oki_inc;
wire [11:0] cfg_oki_wrap;
wire [7:0]  cfg_dswa;
wire [7:0]  cfg_dswb;
wire [7:0]  cfg_jmpr;
wire [1:0]  cfg_gp0_size;
wire [1:0]  cfg_gp1_size;
localparam [2:0] BOARD_TP030 = 3'd0;
localparam [2:0] BOARD_TP022 = 3'd1;
localparam [2:0] BOARD_TP023 = 3'd2;
localparam [2:0] BOARD_TP026 = 3'd3;
wire        tp026 = cfg_board == BOARD_TP026;
wire        loader_eeprom_we;
wire [6:0]  loader_eeprom_addr;
wire [7:0]  loader_eeprom_data;
wire [15:0] main_in3_data;
wire [11:0] tx_vram_addr;
wire [15:0] tx_vram_data;
wire [8:0]  tx_line_addr;
wire [15:0] tx_line_data;
wire [14:0] tx_gfx_addr;
wire [7:0]  tx_gfx_data;
wire        tx_gfx_wr;
wire [14:0] tx_gfx_wr_addr;
wire [7:0]  tx_gfx_wr_old;
wire [9:0]  tx_pixel;
wire [7:0]  sound_port0;
wire        eeprom_do;
wire        loader_audio_we;
wire [14:0] loader_audio_addr;
wire [7:0]  loader_audio_data;
wire [7:0]  sound_rom_data;
wire [7:0]  dswa = cfg_dswa ^ dipsw[7:0];
wire [7:0]  dswb = cfg_dswb ^ dipsw[15:8];
wire [7:0]  jmpr = cfg_jmpr ^ dipsw[23:16];
// MAME: TP-030 PT/P0/P1 = DSWA/DSWB/JMPR; TP-022 PT/P0 swapped.
wire [7:0]  v25_port_t = (cfg_board == BOARD_TP022) ? dswb : dswa;
wire [7:0]  v25_port_0 = (cfg_board == BOARD_TP022) ? dswa : dswb;
wire main_reset = rst || dwnld_busy;
(* preserve *) reg [1:0] sound_reset_pipe = 2'b11;
wire sound_reset = sound_reset_pipe[1];
(* preserve *) reg [1:0] video_reset_pipe = 2'b11;
wire video_reset = video_reset_pipe[1];

wire [15:0] main_in1_data;
wire [15:0] main_in2_data;
wire [15:0] main_sys_data;
wire        main_rom_cs;
wire [17:0] main_rom_addr;
wire [15:0] main_rom_data;
wire        main_rom_ok;
wire        main_rom_rd;
wire        main_irq4;
wire [7:0]  main_coin_control;
wire        main_v25_reset_n;
wire [14:0] sound_shared_addr;
wire [7:0]  sound_shared_dout;
wire [7:0]  sound_shared_din;
wire        sound_shared_we;
wire [17:0] sound_oki_rom_addr;
wire [7:0]  sound_oki_rom_data;
wire        sound_oki_rom_ok;
wire        sound_oki_rom_rd;
wire [AW-1:0] sound_oki_sdram_addr;
wire signed [15:0] sound_mono;
wire        sound_sample;
wire        sound_debug_fault;
wire        sound_debug_halted;
wire [19:0] sound_debug_pc;
wire        sound_debug_state_idle;
wire        sound_debug_v25_reset_n;
wire        sound_debug_ym_write;
wire        sound_debug_ym_a0;
wire [7:0]  sound_debug_ym_data;
wire        sound_debug_oki_write;
wire [7:0]  sound_debug_oki_data;
wire        sound_debug_oki_cen;
wire [7:0]  sound_debug_oki_status;
wire signed [13:0] sound_debug_oki_sound;
wire [12:0] video_gp0_vram_addr;
wire [15:0] video_gp0_vram_data;
wire [12:0] video_gp1_vram_addr;
wire [15:0] video_gp1_vram_data;
wire [12:0] gp0_snapshot_addr;
wire [15:0] gp0_snapshot_data;
wire [12:0] gp1_snapshot_addr;
wire [15:0] gp1_snapshot_data;
wire [9:0]  video_gp0_object_addr;
wire [15:0] video_gp0_object_data;
wire [9:0]  video_gp1_object_addr;
wire [15:0] video_gp1_object_data;
wire [15:0] main_gp0_object_data;
wire [15:0] main_gp1_object_data;
wire        main_gp0_obj_buf_busy;
wire        main_gp1_obj_buf_busy;
wire [127:0] video_gp0_scrolls;
wire [127:0] video_gp1_scrolls;
wire [7:0] video_gp0_scroll_flip;
wire [7:0] video_gp1_scroll_flip;
wire [127:0] main_gp0_scrolls;
wire [127:0] main_gp1_scrolls;
wire [7:0] main_gp0_scroll_flip;
wire [7:0] main_gp1_scroll_flip;
wire [10:0] video_palette_addr;
wire [15:0] video_palette_data;
wire [10:0] palette_snapshot_addr;
wire [15:0] palette_snapshot_data;
wire video_line_ready;
wire [10:0] video_gp0_color;
wire [10:0] video_gp1_color;
wire [3:0] video_engine_busy;
wire [3:0] video_deadline_miss;
wire [15:0] video_gp0_tile_cycles;
wire [15:0] video_gp0_object_cycles;
wire [15:0] video_gp1_tile_cycles;
wire [15:0] video_gp1_object_cycles;
wire [8:0] video_debug_gp0_tile_y;
wire [8:0] video_debug_gp0_object_y;
wire [8:0] video_debug_gp1_tile_y;
wire [8:0] video_debug_gp1_object_y;
wire [3:0] video_debug_line_epoch;
wire [3:0] video_debug_line_valid;
wire video_gp0_tile_req;
wire [21:0] video_gp0_tile_addr;
wire [15:0] video_gp0_tile_data;
wire video_gp0_tile_ok;
wire video_gp0_object_req;
wire [21:0] video_gp0_object_gfx_addr;
wire [15:0] video_gp0_object_gfx_data;
wire video_gp0_object_ok;
wire video_gp1_tile_req;
wire [21:0] video_gp1_tile_addr;
wire [15:0] video_gp1_tile_data;
wire video_gp1_tile_ok;
wire video_gp1_object_req;
wire [21:0] video_gp1_object_gfx_addr;
wire [15:0] video_gp1_object_gfx_data;
wire video_gp1_object_ok;
wire video_gp0_rom_rd;
wire video_gp1_rom_rd;
wire [21:0] video_gp0_tile_physical_addr;
wire [21:0] video_gp0_object_physical_addr;
wire [21:0] video_gp1_tile_physical_addr;
wire [21:0] video_gp1_object_physical_addr;
wire        main_irq4_start = (clkdiv == 4'd13) &&
                              (hcnt == 10'd0) && (vcnt == 9'd230);
wire        main_obj_buf_start = (clkdiv == 4'd13) &&
                                 (hcnt == H_TOTAL - 1'b1) &&
                                 (vcnt == 9'd239);
wire video_line_event = (clkdiv == 4'd13) && (hcnt == H_TOTAL - 1'b1);
wire video_line_start = video_line_event &&
                        ((vcnt < 9'd238) || (vcnt >= 9'd260));
wire video_line_commit = (clkdiv == 4'd13) && (hcnt == H_TOTAL - 1'b1) &&
                         ((vcnt < 9'd239) || (vcnt == V_TOTAL - 1'b1));
wire [8:0] video_target_y = (vcnt >= 9'd260) ?
                            vcnt - 9'd260 : vcnt + 9'd2;
wire video_target_epoch = (vcnt >= 9'd260) ?
                          ~video_epoch : video_epoch;

wire sound_reset_request = main_reset;
wire video_reset_request = main_reset;

dogyuun_rom_loader #(.AW(AW)) u_rom_loader (
    .clk            ( clk                   ),
    // game_rst is asserted throughout an MRA download. The loader must use
    // the framework reset so it remains alive while ioctl_rom is active.
    .rst            ( cold_rst              ),
    .ioctl_rom      ( ioctl_rom             ),
    .ioctl_addr     ( ioctl_addr            ),
    .ioctl_dout     ( ioctl_dout            ),
    .ioctl_wr       ( ioctl_wr              ),
    .dwnld_busy     ( dwnld_busy            ),
    .prog_ba        ( prog_ba               ),
    .prog_addr      ( prog_addr             ),
    .prog_data      ( prog_data             ),
    .prog_mask      ( prog_mask             ),
    .prog_rd        ( prog_rd               ),
    .prog_we        ( prog_we               ),
    .prog_rdy       ( prog_rdy              ),
    .prog_ack       ( prog_ack              ),
    .cfg_valid      ( cfg_valid             ),
    .cfg_board      ( cfg_board             ),
    .cfg_two_gp     ( cfg_two_gp            ),
    .cfg_rot0       ( cfg_rot0              ),
    .cfg_table      ( cfg_table             ),
    .cfg_oki_pin7   ( cfg_oki_pin7          ),
    .cfg_wram_64k   ( cfg_wram_64k          ),
    .cfg_cpu_num    ( cfg_cpu_num           ),
    .cfg_v25_num    ( cfg_v25_num           ),
    .cfg_oki_inc    ( cfg_oki_inc           ),
    .cfg_oki_wrap   ( cfg_oki_wrap          ),
    .cfg_dswa       ( cfg_dswa              ),
    .cfg_dswb       ( cfg_dswb              ),
    .cfg_jmpr       ( cfg_jmpr              ),
    .cfg_gp0_size   ( cfg_gp0_size          ),
    .cfg_gp1_size   ( cfg_gp1_size          ),
    .audio_we       ( loader_audio_we       ),
    .audio_addr     ( loader_audio_addr     ),
    .audio_data     ( loader_audio_data     ),
    .eeprom_we      ( loader_eeprom_we      ),
    .eeprom_addr    ( loader_eeprom_addr    ),
    .eeprom_data    ( loader_eeprom_data    ),
    .accepted       ( loader_accepted       ),
    .range_error    ( loader_range_error    ),
    .overflow_error ( loader_overflow_error ),
    .last_addr      ( loader_last_addr      )
);

assign ioctl_din = 8'h00;

assign ba_rd = {sound_oki_rom_rd, video_gp1_rom_rd,
                video_gp0_rom_rd, main_rom_rd};
assign ba_wr = 4'b0000;
assign ba0_din = 16'h0000;
assign ba1_din = 16'h0000;
assign ba2_din = 16'h0000;
assign ba3_din = 16'h0000;
assign ba0_dsn = 2'b11;
assign ba1_dsn = 2'b11;
assign ba2_dsn = 2'b11;
assign ba3_dsn = 2'b11;
assign ba3_addr = sound_oki_sdram_addr;

dogyuun_gfx_repack u_gp0_tile_repack (
    .size          (cfg_gp0_size),
    .logical_addr  (video_gp0_tile_addr),
    .physical_addr (video_gp0_tile_physical_addr)
);

dogyuun_gfx_repack u_gp0_object_repack (
    .size          (cfg_gp0_size),
    .logical_addr  (video_gp0_object_gfx_addr),
    .physical_addr (video_gp0_object_physical_addr)
);

dogyuun_gfx_repack u_gp1_tile_repack (
    .size          (cfg_gp1_size),
    .logical_addr  (video_gp1_tile_addr),
    .physical_addr (video_gp1_tile_physical_addr)
);

dogyuun_gfx_repack u_gp1_object_repack (
    .size          (cfg_gp1_size),
    .logical_addr  (video_gp1_object_gfx_addr),
    .physical_addr (video_gp1_object_physical_addr)
);

// Dogyuun has no framework-level flip output. Keep the rotation polarity
// deterministic; the game's own Flip Screen DIP remains in dipsw[1].
assign dip_flip = 1'b0;
assign dbg_cfg_valid     = cfg_valid;
assign dbg_loader_error  = loader_range_error | loader_overflow_error;
assign dbg_v25_run       = sound_debug_v25_reset_n;
assign dbg_v25_fault     = sound_debug_fault;
assign dbg_deadline_miss = video_deadline_miss;
assign dbg_oki_busy      = |sound_debug_oki_status[3:0];
assign dbg_v25_pc        = sound_debug_pc;

assign snd_left = sound_mono;
assign snd_right = sound_mono;
assign sample = sound_sample;
assign snd_vu = 6'd0;
assign snd_peak = 1'b0;

dogyuun_inputs u_inputs (
    .tp026     (tp026),
    .joy1_n    (joystick1[6:0]),
    .joy2_n    (joystick2[6:0]),
    .joy3_n    (joystick3[6:0]),
    .start_n   (cab_1p),
    .coin_n    (coin),
    .service_n (service),
    .tilt_n    (tilt),
    .test_n    (dip_test),
    .in1       (main_in1_data),
    .in2       (main_in2_data),
    .in3       (main_in3_data),
    .sys       (main_sys_data)
);

dogyuun_main u_main (
    .clk                 (clk),
    .rst                 (main_reset),
    .halt_n              (dip_pause),
    .cpu_num             (cfg_cpu_num),
    .wram_64k            (cfg_wram_64k),
    .board               (cfg_board),
    .two_gp              (cfg_two_gp),
    .audio_we            (loader_audio_we),
    .audio_addr          (loader_audio_addr),
    .audio_data          (loader_audio_data),
    .rom_cs              (main_rom_cs),
    .rom_addr            (main_rom_addr),
    .rom_data            (main_rom_data),
    .rom_ok              (main_rom_ok),
    .in1_data            (main_in1_data),
    .in2_data            (main_in2_data),
    .sys_data            (main_sys_data),
    .in3_data            (main_in3_data),
    .hcnt                (hcnt),
    .vcnt                (vcnt),
    .irq4_start          (main_irq4_start),
    .sound_clk           (clk),
    .sound_shared_addr   (sound_shared_addr),
    .sound_shared_din    (sound_shared_dout),
    .sound_shared_we     (sound_shared_we),
    .sound_shared_dout   (sound_shared_din),
    .sound_rom_dout      (sound_rom_data),
    .coin_control        (main_coin_control),
    .v25_reset_n         (main_v25_reset_n),
    .palette_scan_addr   (palette_snapshot_addr),
    .palette_scan_dout   (palette_snapshot_data),
    .gp0_scan_addr       (gp0_snapshot_addr),
    .gp0_scan_dout       (gp0_snapshot_data),
    .gp1_scan_addr       (gp1_snapshot_addr),
    .gp1_scan_dout       (gp1_snapshot_data),
    .gp_obj_buf_start    (main_obj_buf_start),
    .gp0_obj_scan_addr   (video_gp0_object_addr),
    .gp0_obj_scan_dout   (main_gp0_object_data),
    .gp1_obj_scan_addr   (video_gp1_object_addr),
    .gp1_obj_scan_dout   (main_gp1_object_data),
    .gp0_obj_buf_busy    (main_gp0_obj_buf_busy),
    .gp1_obj_buf_busy    (main_gp1_obj_buf_busy),
    .gp0_obj_buf_miss    (),
    .gp1_obj_buf_miss    (),
    .gp0_scrolls         (main_gp0_scrolls),
    .gp1_scrolls         (main_gp1_scrolls),
    .gp0_scroll_flip     (main_gp0_scroll_flip),
    .gp1_scroll_flip     (main_gp1_scroll_flip),
    .tx_vram_scan_addr   (tx_vram_addr),
    .tx_vram_scan_dout   (tx_vram_data),
    .tx_line_scan_addr   (tx_line_addr),
    .tx_line_scan_dout   (tx_line_data),
    .tx_gfx_scan_addr    (tx_gfx_addr),
    .tx_gfx_scan_dout    (tx_gfx_data),
    .tx_gfx_wr           (tx_gfx_wr),
    .tx_gfx_wr_addr      (tx_gfx_wr_addr),
    .tx_gfx_wr_old       (tx_gfx_wr_old),
    .irq4                (main_irq4),
    .dbg_pc              (dbg_m68_pc),
    .dbg_rom_rd          (dbg_m68_rom_rd),
    .dbg_halted          (dbg_m68_halted)
);

dogyuun_sound u_sound (
    .reset               (sound_reset),
    .clk                 (clk),
    .v25_enable          (main_v25_reset_n),
    .v25_num             (cfg_v25_num),
    .oki_inc             (cfg_oki_inc),
    .oki_wrap            (cfg_oki_wrap),
    .oki_pin7            (cfg_oki_pin7),
    .secure_mode         (cfg_table == 2'd1),   // nitro; 0 is plain
    .ts001_mode          (cfg_table == 2'd2),   // ts001turbo
    .tp023               (cfg_board == BOARD_TP023),
    .tp026               (tp026),
    .in1                 (main_in1_data[7:0]),
    .in2                 (main_in2_data[7:0]),
    .in3                 (main_in3_data[7:0]),
    .eeprom_do           (eeprom_do),
    .port0_out           (sound_port0),
    .port_t              (v25_port_t),
    .port_0              (v25_port_0),
    .port_1              (jmpr),
    .ym_enable           (snd_en[0]),
    .oki_enable          (snd_en[1]),
    .pause               (!dip_pause),
    .shared_addr         (sound_shared_addr),
    .shared_dout         (sound_shared_dout),
    .shared_we           (sound_shared_we),
    .shared_din          (sound_shared_din),
    .rom_din             (sound_rom_data),
    .oki_rom_addr        (sound_oki_rom_addr),
    .oki_rom_data        (sound_oki_rom_data),
    .oki_rom_ok          (sound_oki_rom_ok),
    .snd_mono            (sound_mono),
    .sample              (sound_sample),
    .debug_fault         (sound_debug_fault),
    .debug_halted        (sound_debug_halted),
    .debug_pc            (sound_debug_pc),
    .debug_state_idle    (sound_debug_state_idle),
    .debug_v25_reset_n   (sound_debug_v25_reset_n),
    .debug_ym_write      (sound_debug_ym_write),
    .debug_ym_a0         (sound_debug_ym_a0),
    .debug_ym_data       (sound_debug_ym_data),
    .debug_oki_write     (sound_debug_oki_write),
    .debug_oki_data      (sound_debug_oki_data),
    .debug_v25_cen       (),
    .debug_ym_cen        (),
    .debug_ym_cen_p1     (),
    .debug_oki_cen       (sound_debug_oki_cen),
    .debug_oki_status    (sound_debug_oki_status),
    .debug_oki_sound     (sound_debug_oki_sound)
);

jtframe_rom_1slot #(
    .SDRAMW        (AW),
    .SLOT0_DW      (16),
    .SLOT0_AW      (18),
    .SLOT0_LATCH   (0),
    .SLOT0_OKLATCH (0),
    .SLOT0_OFFSET  ({AW{1'b0}})
) u_main_rom (
    .rst        (main_reset),
    .clk        (clk),
    .slot0_addr (main_rom_addr),
    .slot0_dout (main_rom_data),
    .slot0_cs   (main_rom_cs),
    .slot0_ok   (main_rom_ok),
    .sdram_ack  (ba_ack[0]),
    .sdram_rd   (main_rom_rd),
    .sdram_addr (ba0_addr),
    .data_dst   (ba_dst[0]),
    .data_rdy   (ba_rdy[0]),
    .data_read  (data_read)
);

dogyuun_gp9001_snapshot u_gp0_snapshot (
    .clk                 (clk),
    .rst                 (video_reset),
    .snapshot_start      (main_obj_buf_start),
    .source_addr         (gp0_snapshot_addr),
    .source_data         (gp0_snapshot_data),
    .source_scrolls      (main_gp0_scrolls),
    .source_scroll_flip  (main_gp0_scroll_flip),
    .display_addr        (video_gp0_vram_addr),
    .display_data        (video_gp0_vram_data),
    .object_addr         (video_gp0_object_addr),
    .object_data         (video_gp0_object_data),
    .display_scrolls     (video_gp0_scrolls),
    .display_scroll_flip (video_gp0_scroll_flip),
    .copy_busy           (),
    .copy_miss           ()
);

dogyuun_gp9001_snapshot u_gp1_snapshot (
    .clk                 (clk),
    .rst                 (video_reset),
    .snapshot_start      (main_obj_buf_start),
    .source_addr         (gp1_snapshot_addr),
    .source_data         (gp1_snapshot_data),
    .source_scrolls      (main_gp1_scrolls),
    .source_scroll_flip  (main_gp1_scroll_flip),
    .display_addr        (video_gp1_vram_addr),
    .display_data        (video_gp1_vram_data),
    .object_addr         (video_gp1_object_addr),
    .object_data         (video_gp1_object_data),
    .display_scrolls     (video_gp1_scrolls),
    .display_scroll_flip (video_gp1_scroll_flip),
    .copy_busy           (),
    .copy_miss           ()
);

dogyuun_gp9001_video u_video (
    .clk                 (clk),
    .rst                 (video_reset),
    .gal_mix             (cfg_board == BOARD_TP030),
    .two_gp              (cfg_two_gp),
    .gp0_gfx_size        (cfg_gp0_size),
    .gp1_gfx_size        (cfg_gp1_size),
    .line_start          (video_line_start),
    .line_commit         (video_line_commit),
    .target_y            (video_target_y),
    .target_epoch        (video_target_epoch),
    .display_x           (hcnt[8:0]),
    .display_y           (vcnt),
    .display_epoch       (video_epoch),
    .gp0_scrolls         (video_gp0_scrolls),
    .gp1_scrolls         (video_gp1_scrolls),
    .gp0_scroll_flip     (video_gp0_scroll_flip),
    .gp1_scroll_flip     (video_gp1_scroll_flip),
    .gp0_vram_addr       (video_gp0_vram_addr),
    .gp0_vram_data       (video_gp0_vram_data),
    .gp1_vram_addr       (video_gp1_vram_addr),
    .gp1_vram_data       (video_gp1_vram_data),
    .gp0_object_addr     (video_gp0_object_addr),
    .gp0_object_data     (video_gp0_object_data),
    .gp1_object_addr     (video_gp1_object_addr),
    .gp1_object_data     (video_gp1_object_data),
    .gp0_tile_gfx_req    (video_gp0_tile_req),
    .gp0_tile_gfx_addr   (video_gp0_tile_addr),
    .gp0_tile_gfx_data   (video_gp0_tile_data),
    .gp0_tile_gfx_ok     (video_gp0_tile_ok),
    .gp0_object_gfx_req  (video_gp0_object_req),
    .gp0_object_gfx_addr (video_gp0_object_gfx_addr),
    .gp0_object_gfx_data (video_gp0_object_gfx_data),
    .gp0_object_gfx_ok   (video_gp0_object_ok),
    .gp1_tile_gfx_req    (video_gp1_tile_req),
    .gp1_tile_gfx_addr   (video_gp1_tile_addr),
    .gp1_tile_gfx_data   (video_gp1_tile_data),
    .gp1_tile_gfx_ok     (video_gp1_tile_ok),
    .gp1_object_gfx_req  (video_gp1_object_req),
    .gp1_object_gfx_addr (video_gp1_object_gfx_addr),
    .gp1_object_gfx_data (video_gp1_object_gfx_data),
    .gp1_object_gfx_ok   (video_gp1_object_ok),
    .line_ready          (video_line_ready),
    .gp0_color           (video_gp0_color),
    .gp1_color           (video_gp1_color),
    .final_color         (video_palette_addr),
    .engine_busy         (video_engine_busy),
    .deadline_miss       (video_deadline_miss),
    .gp0_tile_cycles     (video_gp0_tile_cycles),
    .gp0_object_cycles   (video_gp0_object_cycles),
    .gp1_tile_cycles     (video_gp1_tile_cycles),
    .gp1_object_cycles   (video_gp1_object_cycles),
    .debug_gp0_tile_y    (video_debug_gp0_tile_y),
    .debug_gp0_object_y  (video_debug_gp0_object_y),
    .debug_gp1_tile_y    (video_debug_gp1_tile_y),
    .debug_gp1_object_y  (video_debug_gp1_object_y),
    .debug_line_epoch    (video_debug_line_epoch),
    .debug_line_valid    (video_debug_line_valid)
);

// TP-026's text layer, over everything the GP9001 draws: its palette
// entries are 0x400 + colour x 16 + pen, pen 0 transparent. The palette
// address is registered here: the pixel is taken 14 clocks after the
// display address moves, and the line buffers' outputs are two clocks in.
toaplan_text_layer u_text (
    .clk            (clk),
    .rst            (video_reset),
    .enable         (tp026),
    .snapshot_start (main_obj_buf_start),
    .src_vram_addr  (tx_vram_addr),
    .src_vram_data  (tx_vram_data),
    .src_line_addr  (tx_line_addr),
    .src_line_data  (tx_line_data),
    .gfx_addr       (tx_gfx_addr),
    .gfx_data       (tx_gfx_data),
    .gfx_wr         (tx_gfx_wr),
    .gfx_wr_addr    (tx_gfx_wr_addr),
    .gfx_wr_old     (tx_gfx_wr_old),
    .line_event     (video_line_event),
    .vcnt           (vcnt),
    .display_x      (hcnt[8:0]),
    .pixel          (tx_pixel)
);

reg [10:0] palette_display_addr = 11'd0;
always @(posedge clk)
    palette_display_addr <= (tx_pixel[3:0] != 4'd0) ? {1'b1, tx_pixel} :
                                                     video_palette_addr;

// FixEight's 93C46 on the V25's port 0.
toaplan_93c46 u_eeprom (
    .clk          (clk),
    .rst          (main_reset),
    .cs           (tp026 && sound_port0[4]),
    .sk           (sound_port0[5]),
    .di           (sound_port0[6]),
    .dout         (eeprom_do),
    .seed_we      (loader_eeprom_we),
    .seed_addr    (loader_eeprom_addr),
    .seed_data    (loader_eeprom_data),
    .nv_addr      (nv_addr),
    .nv_din       (nv_din),
    .nv_we        (nv_we),
    .nv_dout      (nv_dout),
    .nv_dirty     (nv_dirty),
    .nv_dirty_clr (nv_dirty_clr)
);
assign cfg_eeprom = tp026;

dogyuun_palette_snapshot u_palette_snapshot (
    .clk            (clk),
    .rst            (video_reset),
    .snapshot_start (main_obj_buf_start),
    .source_addr    (palette_snapshot_addr),
    .source_data    (palette_snapshot_data),
    .display_addr   (palette_display_addr),
    .display_data   (video_palette_data)
);

jtframe_rom_2slots #(
    .SDRAMW        (AW),
    .SLOT0_DW      (16),
    .SLOT1_DW      (16),
    .SLOT0_AW      (22),
    .SLOT1_AW      (22),
    .SLOT0_LATCH   (0),
    .SLOT1_LATCH   (0),
    .SLOT0_OKLATCH (0),
    .SLOT1_OKLATCH (0)
) u_gp0_rom (
    .rst        (video_reset),
    .clk        (clk),
    .slot0_addr (video_gp0_tile_physical_addr),
    .slot1_addr (video_gp0_object_physical_addr),
    .slot0_dout (video_gp0_tile_data),
    .slot1_dout (video_gp0_object_gfx_data),
    .slot0_cs   (video_gp0_tile_req),
    .slot1_cs   (video_gp0_object_req),
    .slot0_ok   (video_gp0_tile_ok),
    .slot1_ok   (video_gp0_object_ok),
    .sdram_ack  (ba_ack[1]),
    .sdram_rd   (video_gp0_rom_rd),
    .sdram_addr (ba1_addr),
    .data_dst   (ba_dst[1]),
    .data_rdy   (ba_rdy[1]),
    .data_read  (data_read)
);

jtframe_rom_2slots #(
    .SDRAMW        (AW),
    .SLOT0_DW      (16),
    .SLOT1_DW      (16),
    .SLOT0_AW      (22),
    .SLOT1_AW      (22),
    .SLOT0_LATCH   (0),
    .SLOT1_LATCH   (0),
    .SLOT0_OKLATCH (0),
    .SLOT1_OKLATCH (0)
) u_gp1_rom (
    .rst        (video_reset),
    .clk        (clk),
    .slot0_addr (video_gp1_tile_physical_addr),
    .slot1_addr (video_gp1_object_physical_addr),
    .slot0_dout (video_gp1_tile_data),
    .slot1_dout (video_gp1_object_gfx_data),
    .slot0_cs   (video_gp1_tile_req),
    .slot1_cs   (video_gp1_object_req),
    .slot0_ok   (video_gp1_tile_ok),
    .slot1_ok   (video_gp1_object_ok),
    .sdram_ack  (ba_ack[2]),
    .sdram_rd   (video_gp1_rom_rd),
    .sdram_addr (ba2_addr),
    .data_dst   (ba_dst[2]),
    .data_rdy   (ba_rdy[2]),
    .data_read  (data_read)
);

jtframe_rom_1slot #(
    .SDRAMW        (AW),
    .SLOT0_DW      (8),
    .SLOT0_AW      (18),
    .SLOT0_LATCH   (0),
    .SLOT0_OKLATCH (0),
    .SLOT0_OFFSET  ({AW{1'b0}})
) u_oki_rom (
    .rst        (sound_reset),
    .clk        (clk),
    .slot0_addr (sound_oki_rom_addr),
    .slot0_dout (sound_oki_rom_data),
    .slot0_cs   (1'b1),
    .slot0_ok   (sound_oki_rom_ok),
    .sdram_ack  (ba_ack[3]),
    .sdram_rd   (sound_oki_rom_rd),
    .sdram_addr (sound_oki_sdram_addr),
    .data_dst   (ba_dst[3]),
    .data_rdy   (ba_rdy[3]),
    .data_read  (data_read)
);

// Assert with the board reset and release in this clock domain. This keeps
// the sound cores' reset fanout off their active arithmetic paths.
always @(posedge clk or posedge sound_reset_request) begin
    if (sound_reset_request)
        sound_reset_pipe <= 2'b11;
    else
        sound_reset_pipe <= {sound_reset_pipe[0], 1'b0};
end

// Keep the renderer's high-fanout reset tree local. Assertion remains
// asynchronous; release is synchronized before any line build can begin.
always @(posedge clk or posedge video_reset_request) begin
    if (video_reset_request)
        video_reset_pipe <= 2'b11;
    else
        video_reset_pipe <= {video_reset_pipe[0], 1'b0};
end

// The board reset sequencer advances on pxl_cen, so this divider must keep
// running while the game reset is asserted. Only the cold reset may stop it.
always @(posedge clk) begin
    if (cold_rst) begin
        clkdiv   <= 4'd0;
        pxl2_cen <= 1'b0;
        pxl_cen  <= 1'b0;
    end else begin
        pxl2_cen <= (clkdiv == 4'd6) || (clkdiv == 4'd13);
        pxl_cen  <= clkdiv == 4'd13;

        if (clkdiv == 4'd13)
            clkdiv <= 4'd0;
        else
            clkdiv <= clkdiv + 1'b1;
    end
end

always @(posedge clk) begin
    if (rst) begin
        hcnt    <= 10'd0;
        vcnt    <= 9'd0;
        video_epoch <= 1'b0;
        red     <= 8'h00;
        green   <= 8'h00;
        blue    <= 8'h00;
        LHBL    <= 1'b0;
        LVBL    <= 1'b0;
        HS      <= 1'b1;
        VS      <= 1'b1;
    end else begin
        if (clkdiv == 4'd13) begin
            LHBL <= hcnt < 10'd320;
            LVBL <= vcnt < 9'd240;
            HS <= !((hcnt >= 10'd340) && (hcnt < 10'd376));
            VS <= !((vcnt >= 9'd244) && (vcnt < 9'd248));

            if (dwnld_busy || (hcnt >= 10'd320) || (vcnt >= 9'd240)) begin
                red   <= 8'h00;
                green <= 8'h00;
                blue  <= 8'h00;
            end else if (!video_line_ready) begin
                red   <= 8'h00;
                green <= 8'h00;
                blue  <= 8'h00;
            end else begin
                red   <= {video_palette_data[4:0], video_palette_data[4:2]};
                green <= {video_palette_data[9:5], video_palette_data[9:7]};
                blue  <= {video_palette_data[14:10], video_palette_data[14:12]};
            end

            if (hcnt == H_TOTAL - 1'b1) begin
                hcnt <= 10'd0;
                if (vcnt == V_TOTAL - 1'b1)
                begin
                    vcnt <= 9'd0;
                    video_epoch <= ~video_epoch;
                end
                else
                    vcnt <= vcnt + 1'b1;
            end else begin
                hcnt <= hcnt + 1'b1;
            end
        end
    end
end

endmodule

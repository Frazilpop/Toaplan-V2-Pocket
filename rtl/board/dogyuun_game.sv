// Dogyuun integration shell: verified ROM loading, board-accurate raster,
// MC68000, encrypted V25/audio subsystem, and dual-GP9001 line renderer.
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

    input      [3:0]   gfx_en
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

dogyuun_gfx_repack #(.GP_INDEX(0)) u_gp0_tile_repack (
    .logical_addr  (video_gp0_tile_addr),
    .physical_addr (video_gp0_tile_physical_addr)
);

dogyuun_gfx_repack #(.GP_INDEX(0)) u_gp0_object_repack (
    .logical_addr  (video_gp0_object_gfx_addr),
    .physical_addr (video_gp0_object_physical_addr)
);

dogyuun_gfx_repack #(.GP_INDEX(1)) u_gp1_tile_repack (
    .logical_addr  (video_gp1_tile_addr),
    .physical_addr (video_gp1_tile_physical_addr)
);

dogyuun_gfx_repack #(.GP_INDEX(1)) u_gp1_object_repack (
    .logical_addr  (video_gp1_object_gfx_addr),
    .physical_addr (video_gp1_object_physical_addr)
);

// Dogyuun has no framework-level flip output. Keep the rotation polarity
// deterministic; the game's own Flip Screen DIP remains in dipsw[1].
assign dip_flip = 1'b0;
assign snd_left = sound_mono;
assign snd_right = sound_mono;
assign sample = sound_sample;
assign snd_vu = 6'd0;
assign snd_peak = 1'b0;

dogyuun_inputs u_inputs (
    .joy1_n    (joystick1[6:0]),
    .joy2_n    (joystick2[6:0]),
    .start_n   (cab_1p),
    .coin_n    (coin),
    .service_n (service),
    .tilt_n    (tilt),
    .test_n    (dip_test),
    .in1       (main_in1_data),
    .in2       (main_in2_data),
    .sys       (main_sys_data)
);

dogyuun_main u_main (
    .clk                 (clk),
    .rst                 (main_reset),
    .halt_n              (dip_pause),
    .rom_cs              (main_rom_cs),
    .rom_addr            (main_rom_addr),
    .rom_data            (main_rom_data),
    .rom_ok              (main_rom_ok),
    .in1_data            (main_in1_data),
    .in2_data            (main_in2_data),
    .sys_data            (main_sys_data),
    .hcnt                (hcnt),
    .vcnt                (vcnt),
    .irq4_start          (main_irq4_start),
    .sound_clk           (clk),
    .sound_shared_addr   (sound_shared_addr),
    .sound_shared_din    (sound_shared_dout),
    .sound_shared_we     (sound_shared_we),
    .sound_shared_dout   (sound_shared_din),
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
    .irq4                (main_irq4)
);

dogyuun_sound u_sound (
    .reset               (sound_reset),
    .clk                 (clk),
    .v25_enable          (main_v25_reset_n),
    .dip_a               (dipsw[7:0]),
    .dip_b               (dipsw[15:8]),
    .region              (dipsw[23:16]),
    .ym_enable           (snd_en[0]),
    .oki_enable          (snd_en[1]),
    .pause               (!dip_pause),
    .shared_addr         (sound_shared_addr),
    .shared_dout         (sound_shared_dout),
    .shared_we           (sound_shared_we),
    .shared_din          (sound_shared_din),
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

dogyuun_palette_snapshot u_palette_snapshot (
    .clk            (clk),
    .rst            (video_reset),
    .snapshot_start (main_obj_buf_start),
    .source_addr    (palette_snapshot_addr),
    .source_data    (palette_snapshot_data),
    .display_addr   (video_palette_addr),
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

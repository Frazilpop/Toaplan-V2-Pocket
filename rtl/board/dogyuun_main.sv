// Dogyuun MC68000 subsystem: exact clock enable, board map, local memories,
// GP9001 CPU ports, VDP status, IRQ4, and the V25 release latch.
// Work RAM is 2^WRAM_AW words: 64 KB (Batsugun) at the default.
module dogyuun_main #(
    parameter integer CPU_FIXED_WAIT = 0,
    parameter integer WRAM_AW = 15
) (
    input              clk,
    input              rst,
    input              halt_n,

    output             rom_cs,
    output     [17:0]  rom_addr,
    input      [15:0]  rom_data,
    input              rom_ok,

    input      [15:0]  in1_data,
    input      [15:0]  in2_data,
    input      [15:0]  sys_data,
    input      [9:0]   hcnt,
    input      [8:0]   vcnt,
    input              irq4_start,

    input              sound_clk,
    input      [14:0]  sound_shared_addr,
    input      [7:0]   sound_shared_din,
    input              sound_shared_we,
    output     [7:0]   sound_shared_dout,
    output reg [7:0]   coin_control,
    output             v25_reset_n,

    input      [10:0]  palette_scan_addr,
    output     [15:0]  palette_scan_dout,
    input      [12:0]  gp0_scan_addr,
    output     [15:0]  gp0_scan_dout,
    input      [12:0]  gp1_scan_addr,
    output     [15:0]  gp1_scan_dout,
    input              gp_obj_buf_start,
    input      [9:0]   gp0_obj_scan_addr,
    output     [15:0]  gp0_obj_scan_dout,
    input      [9:0]   gp1_obj_scan_addr,
    output     [15:0]  gp1_obj_scan_dout,
    output             gp0_obj_buf_busy,
    output             gp1_obj_buf_busy,
    output             gp0_obj_buf_miss,
    output             gp1_obj_buf_miss,
    output     [127:0] gp0_scrolls,
    output     [127:0] gp1_scrolls,
    output     [7:0]   gp0_scroll_flip,
    output     [7:0]   gp1_scroll_flip,

    output             irq4
);

wire [23:1] cpu_addr;
wire [23:0] cpu_addr8 = {cpu_addr, 1'b0};
wire [15:0] cpu_dout;
reg  [15:0] cpu_din = 16'hffff;
wire        cpu_as_n;
wire        cpu_lds_n;
wire        cpu_cen;
wire        cpu_cenb;
wire        cpu_rw;
wire        cpu_uds_n;
wire        cpu_dtack_n;
wire        cpu_fc0;
wire        cpu_fc1;
wire        cpu_fc2;
wire        cpu_vpa_n = ~&{cpu_fc0, cpu_fc1, cpu_fc2, ~cpu_as_n};
wire        cpu_iack = !cpu_as_n && cpu_fc0 && cpu_fc1 && cpu_fc2;

wire cpu_bus_active = !cpu_as_n && (!cpu_uds_n || !cpu_lds_n);
wire cpu_read = cpu_bus_active && cpu_rw;
wire cpu_write = cpu_bus_active && !cpu_rw;
wire cpu_core_reset = rst;

wire rom_bus_cs;
wire rom_read_cs;
wire wram_cs;
wire in1_cs;
wire in2_cs;
wire sys_cs;
wire sound_ctrl_cs;
wire shared_cs;
wire gp0_cs;
wire palette_cs;
wire gp1_cs;
wire vcount_cs;
wire io_cs;
wire gp_cs;
wire mapped_cs;
wire unmapped_cs;

dogyuun_main_decode #(.WRAM_AW(WRAM_AW)) u_decode (
    .addr          (cpu_addr8),
    .bus_active    (cpu_bus_active),
    .rw            (cpu_rw),
    .rom_cs        (rom_bus_cs),
    .rom_read_cs   (rom_read_cs),
    .wram_cs       (wram_cs),
    .in1_cs        (in1_cs),
    .in2_cs        (in2_cs),
    .sys_cs        (sys_cs),
    .sound_ctrl_cs (sound_ctrl_cs),
    .shared_cs     (shared_cs),
    .gp0_cs        (gp0_cs),
    .palette_cs    (palette_cs),
    .gp1_cs        (gp1_cs),
    .vcount_cs     (vcount_cs),
    .io_cs         (io_cs),
    .gp_cs         (gp_cs),
    .mapped_cs     (mapped_cs),
    .unmapped_cs   (unmapped_cs)
);

wire normal_rom_read_cs = rom_read_cs;
assign rom_cs = normal_rom_read_cs;
assign rom_addr = cpu_addr8[18:1];

reg gp_bus_started = 1'b0;
reg gp_bus_done = 1'b0;
wire gp_start = gp_cs && !gp_bus_started && !gp_bus_done;
wire gp0_start = gp_start && gp0_cs;
wire gp1_start = gp_start && gp1_cs;
wire gp0_busy;
wire gp1_busy;
wire gp0_done;
wire gp1_done;
wire [15:0] gp0_dout;
wire [15:0] gp1_dout;
wire gp0_irq_clear;
wire gp1_irq_clear;
wire gp0_vram_write;
wire gp1_vram_write;
wire gp0_scroll_write;
wire gp1_scroll_write;
wire [7:0] gp0_scroll_select;
wire [7:0] gp1_scroll_select;
wire gp_wait = gp_cs && !gp_bus_done;
wire [1:0] gp_we_mask = {!cpu_uds_n, !cpu_lds_n};

wire [9:0] vdp_status_sum = {1'b0, vcnt} + 10'd15;
wire [9:0] vdp_status_v = (vdp_status_sum >= 10'd262) ?
                          vdp_status_sum - 10'd262 : vdp_status_sum;
wire vdp_hsync_n = ~((hcnt > 10'd325) && (hcnt < 10'd380));
wire vdp_vsync_n = ~((vcnt >= 9'd232) && (vcnt <= 9'd245));
wire vdp_fblank_n = vdp_hsync_n && vdp_vsync_n;
wire [15:0] vdp_count_flags = 16'hff00 &
                              (vdp_hsync_n ? 16'hffff : 16'h7fff) &
                              (vdp_vsync_n ? 16'hffff : 16'hbfff) &
                              (vdp_fblank_n ? 16'hffff : 16'hfeff);
wire [15:0] vcount_data = vdp_count_flags |
    ((vdp_status_v < 10'd256) ? {8'h00, vdp_status_v[7:0]} : 16'h00ff);
wire gp_status = vdp_status_v >= 10'd245;

dogyuun_gp9001_cpu u_gp0 (
    .clk               (clk),
    .rst               (rst),
    .start             (gp0_start),
    .rw                (cpu_rw),
    .addr              (cpu_addr8[3:0]),
    .din               (cpu_dout),
    .we_mask           (gp_we_mask),
    .status_bit        (gp_status),
    .busy              (gp0_busy),
    .done              (gp0_done),
    .dout              (gp0_dout),
    .irq_clear         (gp0_irq_clear),
    .scan_addr         (gp0_scan_addr),
    .scan_dout         (gp0_scan_dout),
    .obj_buf_start     (gp_obj_buf_start),
    .obj_scan_addr     (gp0_obj_scan_addr),
    .obj_scan_dout     (gp0_obj_scan_dout),
    .obj_buf_busy      (gp0_obj_buf_busy),
    .obj_buf_miss      (gp0_obj_buf_miss),
    .dbg_ptr           (),
    .dbg_scroll_select (gp0_scroll_select),
    .scrolls           (gp0_scrolls),
    .scroll_flip       (gp0_scroll_flip),
    .vram_write        (gp0_vram_write),
    .scroll_write      (gp0_scroll_write)
);

dogyuun_gp9001_cpu u_gp1 (
    .clk               (clk),
    .rst               (rst),
    .start             (gp1_start),
    .rw                (cpu_rw),
    .addr              (cpu_addr8[3:0]),
    .din               (cpu_dout),
    .we_mask           (gp_we_mask),
    .status_bit        (gp_status),
    .busy              (gp1_busy),
    .done              (gp1_done),
    .dout              (gp1_dout),
    .irq_clear         (gp1_irq_clear),
    .scan_addr         (gp1_scan_addr),
    .scan_dout         (gp1_scan_dout),
    .obj_buf_start     (gp_obj_buf_start),
    .obj_scan_addr     (gp1_obj_scan_addr),
    .obj_scan_dout     (gp1_obj_scan_dout),
    .obj_buf_busy      (gp1_obj_buf_busy),
    .obj_buf_miss      (gp1_obj_buf_miss),
    .dbg_ptr           (),
    .dbg_scroll_select (gp1_scroll_select),
    .scrolls           (gp1_scrolls),
    .scroll_flip       (gp1_scroll_flip),
    .vram_write        (gp1_vram_write),
    .scroll_write      (gp1_scroll_write)
);

always @(posedge clk) begin
    if (cpu_core_reset || !cpu_bus_active || !gp_cs) begin
        gp_bus_started <= 1'b0;
        gp_bus_done <= 1'b0;
    end else begin
        if (gp_start)
            gp_bus_started <= 1'b1;
        if (gp0_done || gp1_done)
            gp_bus_done <= 1'b1;
    end
end

wire cpu_bus_busy = (normal_rom_read_cs && !rom_ok) || gp_wait;
wire [15:0] cpu_fave;
wire [15:0] cpu_fworst;

jtframe_68kdtack_cen #(
    .W(8),
    .MFREQ(94500),
    .WAIT1(CPU_FIXED_WAIT)
) u_cpu_dtack (
    .rst       (cpu_core_reset),
    .clk       (clk),
    .cpu_cen   (cpu_cen),
    .cpu_cenb  (cpu_cenb),
    .bus_cs    (cpu_bus_active),
    .bus_busy  (cpu_bus_busy),
    .bus_legit (1'b0),
    .bus_ack   (1'b0),
    .ASn       (cpu_as_n),
    .DSn       ({cpu_uds_n, cpu_lds_n}),
    .num       (7'd25),
    .den       (8'd189),
    .wait2     (1'b0),
    .wait3     (1'b0),
    .DTACKn    (cpu_dtack_n),
    .fave      (cpu_fave),
    .fworst    (cpu_fworst)
);

fx68k u_main68k (
    .clk      (clk),
    .HALTn    (halt_n),
    .extReset (cpu_core_reset),
    .pwrUp    (cpu_core_reset),
    .enPhi1   (cpu_cen),
    .enPhi2   (cpu_cenb),
    .eRWn     (cpu_rw),
    .ASn      (cpu_as_n),
    .LDSn     (cpu_lds_n),
    .UDSn     (cpu_uds_n),
    .E        (),
    .VMAn     (),
    .FC0      (cpu_fc0),
    .FC1      (cpu_fc1),
    .FC2      (cpu_fc2),
    .BGn      (),
    .oRESETn  (),
    .oHALTEDn (),
    .DTACKn   (cpu_dtack_n),
    .VPAn     (cpu_vpa_n),
    .BERRn    (1'b1),
    .BRn      (1'b1),
    .BGACKn   (1'b1),
    .IPL0n    (1'b1),
    .IPL1n    (1'b1),
    .IPL2n    (~irq4),
    .iEdb     (cpu_din),
    .oEdb     (cpu_dout),
    .eab      (cpu_addr)
);

reg ack_seen = 1'b0;
wire ack_now = cpu_bus_active && !cpu_dtack_n && !ack_seen;
wire [1:0] wram_we = {
    ack_now && wram_cs && cpu_write && !cpu_uds_n,
    ack_now && wram_cs && cpu_write && !cpu_lds_n
};
wire shared_we = ack_now && shared_cs && cpu_write && !cpu_lds_n;
wire [1:0] palette_we = {
    ack_now && palette_cs && cpu_write && !cpu_uds_n,
    ack_now && palette_cs && cpu_write && !cpu_lds_n
};

wire [15:0] wram_dout;
wire [7:0] shared_dout;
wire [15:0] palette_dout;
jtframe_dual_ram16 #(.AW(WRAM_AW)) u_wram (
    .clk0  (clk),
    .data0 (cpu_dout),
    .addr0 (cpu_addr8[WRAM_AW:1]),
    .we0   (wram_we),
    .q0    (wram_dout),
    .clk1  (clk),
    .data1 (16'h0000),
    .addr1 ({WRAM_AW{1'b0}}),
    .we1   (2'b00),
    .q1    ()
);

jtframe_dual_ram #(.DW(8), .AW(15)) u_shared_ram (
    .clk0  (clk),
    .data0 (cpu_dout[7:0]),
    .addr0 (cpu_addr8[15:1]),
    .we0   (shared_we),
    .q0    (shared_dout),
    .clk1  (sound_clk),
    .data1 (sound_shared_din),
    .addr1 (sound_shared_addr),
    .we1   (sound_shared_we),
    .q1    (sound_shared_dout)
);

jtframe_dual_ram16 #(.AW(11)) u_palette_ram (
    .clk0  (clk),
    .data0 (cpu_dout),
    .addr0 (cpu_addr8[11:1]),
    .we0   (palette_we),
    .q0    (palette_dout),
    .clk1  (clk),
    .data1 (16'h0000),
    .addr1 (palette_scan_addr),
    .we1   (2'b00),
    .q1    (palette_scan_dout)
);

wire [15:0] cpu_din_mux =
    normal_rom_read_cs ? rom_data :
    wram_cs ? wram_dout :
    shared_cs ? {8'hff, shared_dout} :
    gp0_cs ? gp0_dout :
    gp1_cs ? gp1_dout :
    palette_cs ? palette_dout :
    in1_cs ? in1_data :
    in2_cs ? in2_data :
    sys_cs ? sys_data :
    vcount_cs ? vcount_data :
    16'hffff;

always @(posedge clk) begin
    if (cpu_core_reset)
        cpu_din <= 16'hffff;
    else if (cpu_read)
        cpu_din <= cpu_din_mux;
end

reg irq4_latch = 1'b0;
assign irq4 = irq4_latch;
always @(posedge clk) begin
    if (rst) begin
        irq4_latch <= 1'b0;
    end else begin
        if (irq4_start)
            irq4_latch <= 1'b1;
        if (gp0_irq_clear || gp1_irq_clear)
            irq4_latch <= 1'b0;
    end
end

assign v25_reset_n = coin_control[5];

always @(posedge clk) begin
    if (rst) begin
        ack_seen <= 1'b0;
        coin_control <= 8'h00;
    end else begin
        if (!cpu_bus_active)
            ack_seen <= 1'b0;
        else if (ack_now)
            ack_seen <= 1'b1;

        if (ack_now && sound_ctrl_cs && cpu_write && !cpu_lds_n)
            coin_control <= cpu_dout[7:0];
    end
end

endmodule

// Lint-only stand-ins for the upstream modules this port leaves out: the
// MiSTer high-score saver, the palette snapshot, the hardware debug probe and
// the V25 debug trace. Same ports as upstream, every output tied to zero, so
// dogyuun_game elaborates as imported. Never part of a build; they go when
// the instances do.

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module dogyuun_highscore (
    input              clk,
    input              reset,
    input              cpu_reset,

    input              config_download,
    input              config_wr,
    input      [26:0]  config_addr,
    input      [7:0]   config_data,

    input              nvram_download,
    input              nvram_upload,
    input              nvram_wr,
    input              nvram_rd,
    input      [26:0]  nvram_addr,
    input      [7:0]   nvram_data,
    output     [7:0]   nvram_q,
    output             nvram_wait,

    input              ss_active,
    input      [12:0]  normal_ram_addr,
    input      [1:0]   normal_ram_we,
    input      [15:0]  normal_ram_data,

    output             hold_request,
    input              hold_ack,
    output             ram_owned,
    output     [12:0]  ram_addr,
    output     [1:0]   ram_we,
    output     [15:0]  ram_data,
    input      [15:0]  ram_q,

    output             dirty,
    output             active,
    output             config_valid
);
assign nvram_q = '0;
assign nvram_wait = '0;
assign hold_request = '0;
assign ram_owned = '0;
assign ram_addr = '0;
assign ram_we = '0;
assign ram_data = '0;
assign dirty = '0;
assign active = '0;
assign config_valid = '0;
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module dogyuun_palette_snapshot (
    input              clk,
    input              rst,
    input              snapshot_start,
    output     [10:0]  source_addr,
    input      [15:0]  source_data,
    input      [10:0]  display_addr,
    output     [15:0]  display_data
);
assign source_addr = '0;
assign display_data = '0;
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module dogyuun_hw_debug #(
    parameter integer AW = 22
) (
    input              clk,
    input              rst,
    input              cold_rst,
    input              ioctl_rom,
    input              dwnld_busy,
    input              prog_we,
    input              prog_rdy,
    input              prog_ack,
    input              loader_accepted,
    input              frame_tick,
    input              pixel_tick,
    input              object_swap,
    input              line_start,
    input              line_commit,
    input      [3:0]   clkdiv,
    input      [9:0]   hcnt,
    input      [8:0]   vcnt,
    input              video_epoch,
    input      [8:0]   video_target_y,
    input              video_target_epoch,
    input              video_line_ready,
    input      [3:0]   video_engine_busy,
    input      [3:0]   video_deadline_miss,
    input      [3:0]   video_deadline_latched,
    input      [15:0]  gp0_tile_cycles,
    input      [15:0]  gp0_object_cycles,
    input      [15:0]  gp1_tile_cycles,
    input      [15:0]  gp1_object_cycles,
    input      [8:0]   gp0_tile_y,
    input      [8:0]   gp0_object_y,
    input      [8:0]   gp1_tile_y,
    input      [8:0]   gp1_object_y,
    input      [3:0]   line_epoch,
    input      [3:0]   line_valid,
    input      [21:0]  gp0_tile_gfx_logical_addr,
    input      [21:0]  gp0_tile_gfx_physical_addr,
    input      [15:0]  gp0_tile_gfx_data,
    input              gp0_tile_gfx_req,
    input              gp0_tile_gfx_ok,
    input      [21:0]  gp0_object_gfx_logical_addr,
    input      [21:0]  gp0_object_gfx_physical_addr,
    input      [15:0]  gp0_object_gfx_data,
    input              gp0_object_gfx_req,
    input              gp0_object_gfx_ok,
    input      [21:0]  gp1_tile_gfx_logical_addr,
    input      [21:0]  gp1_tile_gfx_physical_addr,
    input      [15:0]  gp1_tile_gfx_data,
    input              gp1_tile_gfx_req,
    input              gp1_tile_gfx_ok,
    input      [21:0]  gp1_object_gfx_logical_addr,
    input      [21:0]  gp1_object_gfx_physical_addr,
    input      [15:0]  gp1_object_gfx_data,
    input              gp1_object_gfx_req,
    input              gp1_object_gfx_ok,
    input              main_cpu_cen,
    input              main_cpu_cenb,
    input              main_cpu_bus_active,
    input              main_cpu_rw,
    input      [23:0]  main_cpu_addr,
    input      [15:0]  main_cpu_dout,
    input      [15:0]  main_cpu_din,
    input              main_irq4,
    input      [12:0]  main_gp0_ptr,
    input      [12:0]  main_gp1_ptr,
    input      [23:0]  main_last_fetch,
    input      [31:0]  main_bus_count,
    input      [31:0]  main_rom_count,
    input      [31:0]  main_wram_count,
    input      [31:0]  main_shared_count,
    input      [31:0]  main_gp_count,
    input      [31:0]  main_palette_count,
    input      [31:0]  main_io_count,
    input      [31:0]  main_unmapped_count,
    input      [31:0]  main_irq_count,
    input      [31:0]  main_iack_count,
    input      [15:0]  main_debug_events,
    input      [7:0]   main_coin_control,
    input              main_v25_reset_n,
    input              sound_fault,
    input              sound_halted,
    input      [19:0]  sound_pc,
    input              sound_idle,
    input              sound_v25_reset_n,
    input              sound_ym_write,
    input              sound_ym_a0,
    input      [7:0]   sound_ym_data,
    input              sound_oki_write,
    input      [7:0]   sound_oki_data,
    input              sound_oki_cen,
    input      [7:0]   sound_oki_status,
    input      [14:0]  sound_shared_addr,
    input      [7:0]   sound_shared_dout,
    input              sound_shared_we,
    input      [AW-1:0] ba0_addr,
    input      [AW-1:0] ba1_addr,
    input      [AW-1:0] ba2_addr,
    input      [AW-1:0] ba3_addr,
    input      [3:0]   ba_rd,
    input      [3:0]   ba_ack,
    input      [3:0]   ba_rdy,
    input      [3:0]   ba_dst,
    input              loader_range_error,
    input              loader_overflow_error
);
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module dogyuun_v25_debug_trace #(
    parameter integer DETAIL_AW = 10,
    parameter integer SUMMARY_AW = 8,
    parameter integer CE_PER_EPOCH = 12500000,
    parameter integer SILENCE_CE = 37500000,
    parameter integer KEY_MASK_STUCK_CE = 50000000,
    parameter integer YM_QUALIFY_WRITES = 256,
    parameter integer HEARTBEAT_BITS = 20,
    parameter integer SHARED_SAMPLE_BITS = 8
) (
    input              clk,
    input              reset_n,
    input              clock_enable,
    input              instruction_done,
    input      [19:0]  debug_pc,
    input      [2:0]   active_bank,
    input      [15:0]  arch_flags,
    input      [15:0]  arch_cx,
    input      [15:0]  arch_ix,
    input              halted,
    input              fault,
    input              timer2_pending,
    input              timer2_irq_request,
    input              irq_entry_pending,
    input      [7:0]   tmic0_reg,
    input      [7:0]   ispr_reg,
    input      [4:0]   escape_state,
    input      [7:0]   escape_opcode,
    input              bus_write_start,
    input      [19:0]  bus_write_addr,
    input      [7:0]   bus_write_data,
    input              bank_commit,
    input      [2:0]   bank_cause,
    input      [2:0]   bank_source,
    input      [2:0]   bank_target,
    input      [15:0]  bank_psw,
    input      [15:0]  bank_ip,
    input              restore_event,
    input      [31:0]  control,
    output     [127:0] probe
);
assign probe = '0;
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */


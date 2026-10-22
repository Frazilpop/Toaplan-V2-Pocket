// SPDX-License-Identifier: BSD-3-Clause
//
// Toaplan V2 sound subsystem (V25, YM2151, OKI M6295). All logic remains
// synchronous to the 94.5 MHz game clock; exact board rates are generated as
// clock enables, their ratios from the ROM image's header: the V25 at
// 94.5 x v25_num / 189 MHz (25: 12.5 MHz on TP-022, 32: 16 MHz on TP-030),
// the OKI at 94.5 x oki_inc / oki_wrap.
//
// The V25's map: TP-030, TP-022 and TP-027 put the YM2151 at 00000/1, the
// OKI at 00004 and the shared RAM at 80000-87fff (mirrored to fffff);
// TP-023 (tp023) the shared RAM at 00000-007ff, the YM2151 at 04000/1, the
// OKI at 04002 and its own 32 KB ROM at 80000 (mirrored), read as rom_din.

module dogyuun_sound #(
    parameter integer V25_BUS_PHASES_USE_CEN = 1,
    parameter integer V25_BUS_BYTE_PHASES = 4,
    parameter integer V25_SOUND_WRITE_EXTRA_PHASES = 17,
    parameter integer V25_INSTRUCTION_GAP_PHASES = 1,
    parameter integer V25_REGISTER_INC_GAP_PHASES = 4,
    parameter integer V25_OPCODE_TIMING_PROFILE = 1,
    parameter integer V25_TEST1_IMMEDIATE_DELAY = 26,
    parameter integer V25_TEST1_MEMORY_DELAY = 4
) (
    input                       reset,
    input                       clk,
    input                       v25_enable,
    input      [6:0]            v25_num,
    input      [4:0]            oki_inc,
    input      [11:0]           oki_wrap,
    input                       oki_pin7,
    input                       secure_mode,
    input                       tp023,
    // The V25's input ports, active high as MAME's ports (inverted here as
    // MAME's .exor(0xff)): which DIP bank goes where is the board's.
    input      [7:0]            port_t,
    input      [7:0]            port_0,
    input      [7:0]            port_1,
    input                       ym_enable,
    input                       oki_enable,
    input                       pause,

    output     [14:0]           shared_addr,
    output     [7:0]            shared_dout,
    output                      shared_we,
    input      [7:0]            shared_din,
    input      [7:0]            rom_din,

    output     [17:0]           oki_rom_addr,
    input      [7:0]            oki_rom_data,
    input                       oki_rom_ok,

    output signed [15:0]        snd_mono,
    output                      sample,

    output                      debug_fault,
    output                      debug_halted,
    output     [19:0]           debug_pc,
    output                      debug_state_idle,
    output                      debug_v25_reset_n,
    output reg                  debug_ym_write,
    output reg                  debug_ym_a0,
    output reg [7:0]            debug_ym_data,
    output reg                  debug_oki_write,
    output reg [7:0]            debug_oki_data,
    output                      debug_v25_cen,
    output                      debug_ym_cen,
    output                      debug_ym_cen_p1,
    output                      debug_oki_cen,
    output     [7:0]            debug_oki_status,
    output signed [13:0]        debug_oki_sound
);

wire [19:0] YM_ADDR  = tp023 ? 20'h04000 : 20'h00000;
wire [19:0] YM_DATA  = tp023 ? 20'h04001 : 20'h00001;
wire [19:0] OKI_DATA = tp023 ? 20'h04002 : 20'h00004;
wire sound_domain_reset = reset;
reg  pause_held = 1'b0;
wire pause_quiescent;
wire pause_freeze = pause_held || (pause && pause_quiescent);

reg [7:0] v25_cen_accum = 8'd0;
reg       v25_cen = 1'b0;
always @(posedge clk) begin
    if (sound_domain_reset) begin
        v25_cen_accum <= 8'd0;
        v25_cen <= 1'b0;
    end else if (pause_freeze) begin
        v25_cen <= 1'b0;
    end else if (v25_cen_accum >= 8'd189 - v25_num) begin
        v25_cen_accum <= v25_cen_accum + v25_num - 8'd189;
        v25_cen <= 1'b1;
    end else begin
        v25_cen_accum <= v25_cen_accum + v25_num;
        v25_cen <= 1'b0;
    end
end

reg [5:0] ym_divider = 6'd0;
reg       ym_cen = 1'b0;
reg       ym_cen_p1 = 1'b0;
always @(posedge clk) begin
    ym_cen <= 1'b0;
    ym_cen_p1 <= 1'b0;
    if (sound_domain_reset) begin
        ym_divider <= 6'd0;
    end else if (pause_freeze) begin
        ym_divider <= ym_divider;
    end else if (ym_divider == 6'd55) begin
        ym_divider <= 6'd0;
        ym_cen <= 1'b1;
        ym_cen_p1 <= 1'b1;
    end else begin
        ym_divider <= ym_divider + 6'd1;
        if (ym_divider == 6'd27)
            ym_cen <= 1'b1;
    end
end

// 94.5 MHz * 25 / 2268 = 25 MHz / 24 exactly (TP-022); * 8 / 189 = 4 MHz
// (TP-030); * 2 / 189 = 1 MHz.
reg [11:0] oki_cen_accum = 12'd0;
reg        oki_cen = 1'b0;
always @(posedge clk) begin
    oki_cen <= 1'b0;
    if (sound_domain_reset) begin
        oki_cen_accum <= 12'd0;
    end else if (pause_freeze) begin
        oki_cen_accum <= oki_cen_accum;
    end else if (oki_cen_accum >= oki_wrap - oki_inc) begin
        oki_cen_accum <= oki_cen_accum + oki_inc - oki_wrap;
        oki_cen <= oki_inc != 5'd0;
    end else begin
        oki_cen_accum <= oki_cen_accum + oki_inc;
    end
end

// Hold reset through a complete OPM slot rotation before releasing the chip.
reg [5:0] ym_reset_count = 6'd0;
always @(posedge clk or posedge sound_domain_reset) begin
    if (sound_domain_reset)
        ym_reset_count <= 6'd0;
    else if (!pause_freeze && !ym_reset_count[5] && ym_cen_p1)
        ym_reset_count <= ym_reset_count + 6'd1;
end
wire ym_reset = sound_domain_reset || !ym_reset_count[5];
wire ym_ready = !ym_reset;

// JT6295's channel acknowledge shift register has no reset. Prime one full
// rotation, assert decoder reset, then release from a known state.
reg [1:0]  oki_reset_state = 2'd0;
reg [13:0] oki_reset_timer = 14'd0;
reg        oki_reset = 1'b1;
reg        oki_ready = 1'b0;
always @(posedge clk or posedge sound_domain_reset) begin
    if (sound_domain_reset) begin
        oki_reset_state <= 2'd0;
        oki_reset_timer <= 14'd0;
        oki_reset <= 1'b1;
        oki_ready <= 1'b0;
    end else if (!pause_freeze) begin
        case (oki_reset_state)
            2'd0: begin
                oki_reset <= 1'b0;
                if (&oki_reset_timer) begin
                    oki_reset_state <= 2'd1;
                    oki_reset_timer <= 14'd0;
                    oki_reset <= 1'b1;
                end else begin
                    oki_reset_timer <= oki_reset_timer + 14'd1;
                end
            end
            2'd1: begin
                oki_reset <= 1'b1;
                if (oki_reset_timer == 14'd15) begin
                    oki_reset_state <= 2'd2;
                    oki_reset_timer <= 14'd0;
                    oki_reset <= 1'b0;
                    oki_ready <= 1'b1;
                end else begin
                    oki_reset_timer <= oki_reset_timer + 14'd1;
                end
            end
            default: begin
                oki_reset <= 1'b0;
                oki_ready <= 1'b1;
            end
        endcase
    end
end

wire sound_ready = ym_ready && oki_ready;
// Qualify only the initial V25 release with device readiness.
reg v25_started = 1'b0;
always @(posedge clk or posedge reset) begin
    if (reset)
        v25_started <= 1'b0;
    else if (!v25_enable)
        v25_started <= 1'b0;
    else if (sound_ready)
        v25_started <= 1'b1;
end

wire v25_reset_async = reset ||
                       !v25_enable ||
                       !v25_started;
reg [1:0] v25_reset_pipe = 2'b11;
always @(posedge clk or posedge v25_reset_async) begin
    if (v25_reset_async)
        v25_reset_pipe <= 2'b11;
    else
        v25_reset_pipe <= {v25_reset_pipe[0], 1'b0};
end
wire v25_reset_n = !v25_reset_pipe[1];

wire [19:0] v25_bus_addr;
wire [7:0]  v25_bus_dout;
reg  [7:0]  v25_bus_din;
wire        v25_bus_doe;
wire        v25_bus_r_w;
wire        v25_bus_mreq_n;
wire        v25_bus_mstb_n;
wire        v25_bus_iostb_n;
wire        v25_state_idle;

dogyuun_v25_cpu #(
    .BUS_PHASES_USE_CEN (V25_BUS_PHASES_USE_CEN),
    .BUS_BYTE_PHASES    (V25_BUS_BYTE_PHASES),
    .SOUND_WRITE_EXTRA_PHASES (V25_SOUND_WRITE_EXTRA_PHASES),
    .INSTRUCTION_GAP_PHASES (V25_INSTRUCTION_GAP_PHASES),
    .REGISTER_INC_GAP_PHASES (V25_REGISTER_INC_GAP_PHASES),
    .OPCODE_TIMING_PROFILE (V25_OPCODE_TIMING_PROFILE),
    .TEST1_IMMEDIATE_DELAY (V25_TEST1_IMMEDIATE_DELAY),
    .TEST1_MEMORY_DELAY (V25_TEST1_MEMORY_DELAY)
) u_v25 (
    .clk               (clk),
    .reset             (reset),
    .reset_n           (v25_reset_n),
    .clock_enable      (v25_cen && !pause_freeze),
    .secure_mode       (secure_mode),
    .tp023             (tp023),
    .port0_in          (~port_0),
    .port1_in          (~port_1),
    .portt_in          (~port_t),
    .bus_addr          (v25_bus_addr),
    .bus_dout          (v25_bus_dout),
    .bus_din           (v25_bus_din),
    .bus_doe           (v25_bus_doe),
    .bus_r_w           (v25_bus_r_w),
    .bus_mreq_n        (v25_bus_mreq_n),
    .bus_mstb_n        (v25_bus_mstb_n),
    .bus_iostb_n       (v25_bus_iostb_n),
    .halted            (debug_halted),
    .fault             (debug_fault),
    .debug_pc          (debug_pc),
    .state_idle        (v25_state_idle)
);

wire v25_mem_active = !v25_bus_mreq_n && !v25_bus_mstb_n;
wire v25_write_active = v25_mem_active && !v25_bus_r_w && v25_bus_doe;
reg  v25_write_active_d = 1'b0;
wire v25_write_start = v25_write_active && !v25_write_active_d;
wire v25_shared_cs = tp023 ? (v25_bus_addr[19:11] == 9'd0) : v25_bus_addr[19];
wire v25_rom_cs = tp023 && v25_bus_addr[19];

assign shared_addr = v25_bus_addr[14:0];
assign shared_dout = v25_bus_dout;
assign shared_we = v25_write_start && v25_shared_cs;

wire [7:0] ym_dout;
wire [7:0] oki_dout;
always @(*) begin
    v25_bus_din = 8'h00;
    if (v25_mem_active && v25_bus_r_w) begin
        if (v25_shared_cs)
            v25_bus_din = shared_din;
        else if (v25_rom_cs)
            v25_bus_din = rom_din;
        else if (v25_bus_addr == YM_DATA)
            v25_bus_din = ym_dout;
        else if (v25_bus_addr == OKI_DATA)
            v25_bus_din = oki_dout;
    end
end

reg       ym_cs_n = 1'b1;
reg       ym_wr_n = 1'b1;
reg       ym_host_a0 = 1'b0;
reg [7:0] ym_host_data = 8'h00;
reg       ym_write_pending = 1'b0;
reg       oki_wr_n = 1'b1;
reg [7:0] oki_host_data = 8'h00;

always @(posedge clk) begin
    if (!v25_reset_n) begin
        v25_write_active_d <= 1'b0;
        ym_cs_n <= 1'b1;
        ym_wr_n <= 1'b1;
        ym_host_a0 <= 1'b0;
        ym_host_data <= 8'h00;
        ym_write_pending <= 1'b0;
        oki_wr_n <= 1'b1;
        oki_host_data <= 8'h00;
        debug_ym_write <= 1'b0;
        debug_ym_a0 <= 1'b0;
        debug_ym_data <= 8'h00;
        debug_oki_write <= 1'b0;
        debug_oki_data <= 8'h00;
    end else if (!pause_freeze) begin
        v25_write_active_d <= v25_write_active;
        oki_wr_n <= 1'b1;
        debug_ym_write <= 1'b0;
        debug_oki_write <= 1'b0;

        // Hold each V25 write through cen_p1 so the fully synchronous OPM
        // host synchronizer cannot lose a transaction between phiM ticks.
        if (ym_write_pending) begin
            ym_cs_n <= 1'b0;
            ym_wr_n <= 1'b0;
            if (ym_cen_p1) begin
                ym_cs_n <= 1'b1;
                ym_wr_n <= 1'b1;
                ym_write_pending <= 1'b0;
            end
        end else begin
            ym_cs_n <= 1'b1;
            ym_wr_n <= 1'b1;
        end

        if (v25_write_start && !v25_shared_cs) begin
            if (v25_bus_addr == YM_ADDR ||
                v25_bus_addr == YM_DATA) begin
                ym_cs_n <= 1'b0;
                ym_wr_n <= 1'b0;
                ym_host_a0 <= v25_bus_addr[0];
                ym_host_data <= v25_bus_dout;
                ym_write_pending <= 1'b1;
                debug_ym_write <= 1'b1;
                debug_ym_a0 <= v25_bus_addr[0];
                debug_ym_data <= v25_bus_dout;
            end else if (v25_bus_addr == OKI_DATA) begin
                oki_wr_n <= 1'b0;
                oki_host_data <= v25_bus_dout;
                debug_oki_write <= 1'b1;
                debug_oki_data <= v25_bus_dout;
            end
        end
    end
end

wire ym_sample;
wire signed [15:0] ym_left;
wire signed [15:0] ym_right;
wire ym_chip_reset = ym_reset;

dogyuun_opm u_ym2151 (
    .rst    (ym_chip_reset),
    .clk    (clk),
    .cen    (ym_cen),
    .cs_n   (ym_cs_n),
    .wr_n   (ym_wr_n),
    .a0     (ym_host_a0),
    .din    (ym_host_data),
    .dout   (ym_dout),
    .sample (ym_sample),
    .left   (ym_left),
    .right  (ym_right)
);

wire signed [13:0] oki_sound;
wire oki_sample;
wire oki_chip_reset = oki_reset;
jt6295 #(.INTERPOL(0)) u_oki6295 (
    .rst      (oki_chip_reset),
    .clk      (clk),
    .cen      (oki_cen),
    .ss       (oki_pin7),
    .wrn      (oki_wr_n),
    .din      (oki_host_data),
    .dout     (oki_dout),
    .rom_addr (oki_rom_addr),
    .rom_data (oki_rom_data),
    .rom_ok   (oki_rom_ok),
    .sound    (oki_sound),
    .sample   (oki_sample)
);

wire signed [15:0] mixed_mono;

dogyuun_sound_mixer u_mixer (
    .clk        (clk),
    .reset      (ym_chip_reset),
    .sample     (ym_sample),
    .ym_left    (ym_left),
    .ym_right   (ym_right),
    .oki        (oki_sound),
    .ym_enable  (ym_enable),
    .oki_enable (oki_enable),
    .oki_ready  (oki_ready),
    .mono       (mixed_mono)
);

assign snd_mono = pause ? 16'sd0 : mixed_mono;
assign sample = ym_sample;
assign debug_state_idle = v25_state_idle;
wire state_idle = v25_state_idle &&
                  !v25_write_active &&
                  !ym_write_pending &&
                  ym_cs_n && ym_wr_n && oki_wr_n;
assign pause_quiescent = sound_ready && state_idle &&
                         !v25_cen && !ym_cen && !ym_cen_p1 && !oki_cen;

always @(posedge clk) begin
    if (sound_domain_reset || !pause)
        pause_held <= 1'b0;
    else if (pause_quiescent)
        pause_held <= 1'b1;
end

assign debug_v25_reset_n = v25_reset_n;
assign debug_v25_cen = v25_cen;
assign debug_ym_cen = ym_cen;
assign debug_ym_cen_p1 = ym_cen_p1;
assign debug_oki_cen = oki_cen;
assign debug_oki_status = oki_dout;
assign debug_oki_sound = oki_sound;

endmodule

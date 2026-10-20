// SPDX-License-Identifier: BSD-3-Clause
//
// Dogyuun-specific NEC V25 integration. The instruction engine is the local
// opcode-decrypting compact core; this wrapper supplies the V25 register banks,
// exercised extended opcodes, internal registers, and periodic timer.
//
// The 256-byte internal RAM is block RAM (dogyuun_v25_iram below), 16 rows of
// 16 bytes. A register bank is two rows: A holds offsets 00-0f (vector PC,
// saved PSW, saved PC, DS, SS, CS, ES), B offsets 10-1f (DI, SI, BP, SP, BX,
// DX, CX, AX). The board clock is several times the V25's enable, so a bank
// switch reads and writes its rows in the clocks between two enables.

`timescale 1ns/1ns

module dogyuun_v25_cpu #(
    parameter integer BUS_PHASES_USE_CEN = 1,
    parameter integer BUS_BYTE_PHASES = 4,
    parameter integer SOUND_WRITE_EXTRA_PHASES = 17,
    parameter integer INSTRUCTION_GAP_PHASES = 0,
    parameter integer REGISTER_INC_GAP_PHASES = 0,
    parameter integer OPCODE_TIMING_PROFILE = 0,
    parameter integer TEST1_IMMEDIATE_DELAY = 19,
    parameter integer TEST1_MEMORY_DELAY = 0
) (
    input             clk,
    input             reset,
    input             reset_n,
    input             clock_enable,

    // Opcode decryption (the nitro table): on for TP-022, off for TP-030's
    // plain code, from the image header's table id.
    input             secure_mode,

    input      [7:0]  port0_in,
    input      [7:0]  port1_in,
    input      [7:0]  portt_in,

    output     [19:0] bus_addr,
    output     [7:0]  bus_dout,
    input      [7:0]  bus_din,
    output            bus_doe,
    output            bus_r_w,
    output            bus_mreq_n,
    output            bus_mstb_n,
    output            bus_iostb_n,

    output            halted,
    output            fault,
    output     [19:0] debug_pc,
    output            state_idle
);

localparam [4:0]
    ESC_IDLE           = 5'd0,
    ESC_OPCODE         = 5'd1,
    ESC_MODRM          = 5'd2,
    ESC_DISP8          = 5'd3,
    ESC_DISP_LO        = 5'd4,
    ESC_DISP_HI        = 5'd5,
    ESC_IMMEDIATE      = 5'd6,
    ESC_PREPARE        = 5'd7,
    ESC_MEM_READ       = 5'd8,
    ESC_MEM_GAP        = 5'd9,
    ESC_MEM_WRITE      = 5'd10,
    ESC_FLAGS_COMMIT   = 5'd11,
    ESC_DONE_COMMIT    = 5'd12,
    ESC_LOAD_COMMIT    = 5'd13,
    ESC_FAULT_COMMIT   = 5'd14,
    ESC_PUSH_WRITE     = 5'd15;

localparam [3:0]
    BUS_IDLE           = 4'd0,
    BUS_INTERNAL       = 4'd1,
    BUS_EXT_WAIT1      = 4'd2,
    BUS_EXT_WAIT2      = 4'd3,
    BUS_EXT_GAP        = 4'd4,
    BUS_ACK_CPU        = 4'd5,
    BUS_DROP_CPU       = 4'd6,
    BUS_ACK_EXT        = 4'd7,
    BUS_DROP_EXT       = 4'd8,
    BUS_EXT_WAIT3      = 4'd9;

localparam [2:0]
    LOAD_PREP_NONE     = 3'd0,
    LOAD_PREP_REGISTER = 3'd1,
    LOAD_PREP_BANK     = 3'd2,
    LOAD_PREP_PUSH     = 3'd3,
    LOAD_PREP_STACK    = 3'd4;

localparam [1:0]
    RD_NONE = 2'd0,
    RD_REF  = 2'd1,
    RD_BUS0 = 2'd2,
    RD_BUS1 = 2'd3;

reg [2:0] active_bank;

// Bank switches capture a complete register-bank transaction here, then
// commit it over the next three master clocks (rows written, target rows
// read), before the V25's next enable.
reg        bank_commit_pending;
reg        bank_commit_write_return;
reg [2:0]  bank_commit_source;
reg [2:0]  bank_commit_target;
reg [15:0] bank_commit_psw;
reg [15:0] bank_commit_ip;

// Every custom architectural load is prepared from this local snapshot on a
// later master edge. The compact CPU remains held in ESC_LOAD_COMMIT until
// the transaction retires, so this pipeline does not consume a V25 clock.
reg [15:0] arch_stage_ds;
reg [15:0] arch_stage_ss;
reg [15:0] arch_stage_cs;
reg [15:0] arch_stage_es;
reg [15:0] arch_stage_di;
reg [15:0] arch_stage_si;
reg [15:0] arch_stage_bp;
reg [15:0] arch_stage_sp;
reg [15:0] arch_stage_bx;
reg [15:0] arch_stage_dx;
reg [15:0] arch_stage_cx;
reg [15:0] arch_stage_ax;
reg        load_prepare_pending;
reg [2:0]  load_prepare_mode;
reg [2:0]  load_prepare_bank;
reg        load_prepare_target_was_active;
reg        load_prepare_vector;
reg        load_prepare_word;
reg [1:0]  eng_step;
reg [2:0]  load_prepare_register;
reg [15:0] load_prepare_value;
reg [15:0] load_prepare_ip;
reg [15:0] load_prepare_flags;

reg [7:0] idb_reg;
reg       ramen;
reg [7:0] prc_reg;
reg [7:0] p0_latch;
reg [7:0] p1_latch;
reg [7:0] p2_latch;
reg [7:0] pm0_reg;
reg [7:0] pm1_reg;
reg [7:0] pm2_reg;
reg [7:0] pmt_reg;
reg [7:0] rfm_reg;
reg [7:0] wtc_lo;
reg [7:0] wtc_hi;
reg [15:0] md1_reg;
reg [7:0] tmc0_reg;
reg [7:0] tmc1_reg;
reg [7:0] tmic0_reg;
reg [7:0] tmic1_reg;
reg [7:0] tmic2_reg;
reg [7:0] ispr_reg;
reg [31:0] timer_count;
reg        timer2_pending;
reg        irq_entry_pending;

wire [19:0] cpu_addr;
wire [15:0] cpu_dout;
reg  [15:0] cpu_din;
wire        cpu_wr;
wire        cpu_rd;
wire        cpu_io;
wire        cpu_word;
wire        cpu_data_cycle;
wire        cpu_ready;

wire [15:0] arch_ax;
wire [15:0] arch_cx;
wire [15:0] arch_dx;
wire [15:0] arch_bx;
wire [15:0] arch_sp;
wire [15:0] arch_bp;
wire [15:0] arch_si;
wire [15:0] arch_di;
wire [15:0] arch_cs;
wire [15:0] arch_ds;
wire [15:0] arch_es;
wire [15:0] arch_ss;
wire [15:0] arch_next_ip;
wire [15:0] arch_flags;
wire        arch_halted;
wire        arch_segment_override;
wire [15:0] arch_override_segment;
wire        instruction_done;
wire [7:0]  instruction_opcode;
wire        instruction_idle;
wire        interrupt_deferred;

wire        escape_active;
wire [7:0]  escape_lead;
wire [7:0]  escape_byte;
wire        escape_byte_valid;
wire        escape_pop;
wire        escape_complete;

reg  [4:0]  escape_state;
reg  [4:0]  escape_delay_count;
reg  [4:0]  instruction_gap_count;
reg         escape_timing_profile;
reg  [7:0]  escape_opcode;
reg  [7:0]  escape_modrm;
reg  [15:0] escape_disp;
reg  [7:0]  escape_imm;
reg  [3:0]  escape_bit;
reg  [15:0] escape_mem_value;
reg  [15:0] commit_flags;
reg         fault_latch;

reg  [15:0] load_ax;
reg  [15:0] load_cx;
reg  [15:0] load_dx;
reg  [15:0] load_bx;
reg  [15:0] load_sp;
reg  [15:0] load_bp;
reg  [15:0] load_si;
reg  [15:0] load_di;
reg  [15:0] load_cs;
reg  [15:0] load_ds;
reg  [15:0] load_es;
reg  [15:0] load_ss;
reg  [15:0] load_ip;
reg  [15:0] load_flags;

reg         ext_req;
reg         ext_write;
reg         ext_word;
reg  [19:0] ext_addr;
reg  [15:0] ext_dout;
wire [15:0] ext_din;
wire        ext_ready;

reg  [3:0]  bus_state;
reg  [4:0]  bus_wait_phase;
reg         txn_ext;
reg         txn_write;
reg         txn_word;
reg         txn_io;
reg         txn_internal;
reg         txn_phase;
reg  [19:0] txn_addr;
reg  [15:0] txn_dout;
reg  [15:0] txn_din;

// Internal RAM port and its users: reset clear, bank-switch engine, the bus's
// byte accesses, and a background read of the active bank's row A that keeps
// the saved PSW and PC ready for RETRBI and MOVSPB.
reg  [3:0]   iram_raddr;
reg  [3:0]   iram_waddr;
reg  [15:0]  iram_be;
reg  [127:0] iram_wdata;
wire [127:0] iram_q;
wire         iram_we = |iram_be;
reg          iram_we_d;
reg  [1:0]   rd_tag;
reg  [2:0]   ref_bank;
reg  [4:0]   clr_cnt = 5'd0;
reg          clr_reset_n_d = 1'b1;
wire         clr_busy = !clr_cnt[4];
reg  [1:0]   int_step;
reg  [7:0]   int_rd0;
reg  [7:0]   int_rd1;
reg  [31:0]  psw_cache;
reg  [2:0]   psw_bank;
reg          psw_valid;
wire         psw_ok = psw_valid && psw_bank == active_bank;

wire escape_timing_done = escape_delay_count == 5'd0;
wire base_arch_load = escape_timing_done &&
                      escape_state == ESC_LOAD_COMMIT &&
                      !load_prepare_pending;
wire cpu_arch_load = base_arch_load;
wire cpu_clock_enable = clock_enable;
wire bus_phase_advance = !BUS_PHASES_USE_CEN || clock_enable;
wire txn_sound_write = txn_write &&
                       (txn_addr == 20'h00000 ||
                        txn_addr == 20'h00001 ||
                        txn_addr == 20'h00004);
wire [5:0] txn_byte_phases = BUS_BYTE_PHASES +
                             (txn_sound_write ?
                              SOUND_WRITE_EXTRA_PHASES : 0);
wire base_flags_write = escape_timing_done &&
                        escape_state == ESC_FLAGS_COMMIT;
wire timer2_irq_request = timer2_pending && !tmic2_reg[6] &&
                          arch_flags[9];
wire base_fetch_hold = escape_state == ESC_LOAD_COMMIT;
wire interrupt_start_hold = timer2_irq_request &&
                            !interrupt_deferred;
wire instruction_is_register_inc =
    instruction_opcode >= 8'h40 && instruction_opcode <= 8'h47;
wire [19:0] instruction_next_pc =
    {arch_cs, 4'b0000} + {4'b0000, arch_next_ip};
wire instruction_timing_profile_active =
    OPCODE_TIMING_PROFILE != 0 &&
    instruction_next_pc >= 20'ha4000 &&
    instruction_next_pc < 20'ha6000;

function automatic [4:0] opcode_timing_gap(input [7:0] opcode);
begin
    opcode_timing_gap = 5'd0;
    if (instruction_timing_profile_active) begin
        case (opcode)
            8'h0a: opcode_timing_gap = 5'd6;
            8'h0c: opcode_timing_gap = 5'd13;
            8'h24: opcode_timing_gap = 5'd12;
            8'h32: opcode_timing_gap = 5'd8;
            8'h3c: opcode_timing_gap = 5'd13;
            8'h43: opcode_timing_gap = 5'd2;
            8'h50: opcode_timing_gap = 5'd16;
            8'h51: opcode_timing_gap = 5'd13;
            8'h55: opcode_timing_gap = 5'd13;
            8'h58: opcode_timing_gap = 5'd13;
            8'h59: opcode_timing_gap = 5'd15;
            8'h5d: opcode_timing_gap = 5'd8;
            8'h88: opcode_timing_gap = 5'd4;
            8'h8b: opcode_timing_gap = 5'd3;
            8'hb1: opcode_timing_gap = 5'd11;
            8'hb5: opcode_timing_gap = 5'd13;
            8'hbb: opcode_timing_gap = 5'd16;
            8'hbf: opcode_timing_gap = 5'd11;
            8'hc3: opcode_timing_gap = 5'd11;
            8'hd0: opcode_timing_gap = 5'd6;
            8'hd1: opcode_timing_gap = 5'd10;
            8'he8: opcode_timing_gap = 5'd7;
            8'hfe: opcode_timing_gap = 5'd1;
            default: opcode_timing_gap = 5'd0;
        endcase
    end
end
endfunction

wire [4:0] instruction_gap_load =
    INSTRUCTION_GAP_PHASES +
    (instruction_is_register_inc ? REGISTER_INC_GAP_PHASES : 0) +
    opcode_timing_gap(instruction_opcode);
wire instruction_gap_start =
    instruction_done && instruction_gap_load != 5'd0;
wire base_instruction_start_hold =
    interrupt_start_hold || instruction_gap_start ||
    instruction_gap_count != 5'd0;
wire irq_entry_safe = instruction_idle && bus_state == BUS_IDLE &&
                      !cpu_rd && !cpu_wr && !ext_req &&
                      !interrupt_deferred;
assign escape_complete = escape_timing_done &&
                         (escape_state == ESC_FLAGS_COMMIT ||
                          escape_state == ESC_DONE_COMMIT ||
                          escape_state == ESC_FAULT_COMMIT);
assign escape_pop = escape_byte_valid &&
                    (escape_state == ESC_OPCODE ||
                     escape_state == ESC_MODRM ||
                     escape_state == ESC_DISP8 ||
                     escape_state == ESC_DISP_LO ||
                     escape_state == ESC_DISP_HI ||
                     escape_state == ESC_IMMEDIATE);

assign halted = arch_halted;
assign fault = fault_latch;
assign debug_pc = instruction_next_pc;
assign state_idle = reset_n &&
                    instruction_idle &&
                    (bus_state == BUS_IDLE) &&
                    !cpu_rd &&
                    !cpu_wr &&
                    !ext_req &&
                    (escape_state == ESC_IDLE) &&
                    !escape_active &&
                    !arch_segment_override &&
                    !interrupt_deferred &&
                    !timer2_irq_request &&
                    !irq_entry_pending &&
                    !bank_commit_pending &&
                    !load_prepare_pending;

wire bus_external_active = bus_state == BUS_EXT_WAIT1;
wire [19:0] bus_byte_addr = txn_addr + (txn_phase ? 20'd1 : 20'd0);
assign bus_addr = bus_byte_addr;
assign bus_dout = txn_phase ? txn_dout[15:8] : txn_dout[7:0];
assign bus_doe = bus_external_active && txn_write;
assign bus_r_w = ~txn_write;
assign bus_mreq_n = ~(bus_external_active && !txn_io);
assign bus_mstb_n = ~bus_external_active;
assign bus_iostb_n = ~(bus_external_active && txn_io);
assign ext_din = txn_din;
assign ext_ready = bus_state == BUS_ACK_EXT;
assign cpu_ready = bus_state == BUS_ACK_CPU;

wire [8:0] int_index0 = txn_addr[8:0];
wire [8:0] int_index1 = txn_addr[8:0] + 9'd1;
wire int_write0 = bus_state == BUS_INTERNAL && txn_write;
wire int_write1 = int_write0 && txn_word;
wire eng_ram = load_prepare_pending &&
               (load_prepare_mode == LOAD_PREP_BANK ||
                load_prepare_mode == LOAD_PREP_STACK);
wire int_go = bus_state == BUS_INTERNAL && !int_step[1] &&
              !eng_ram && !clr_busy;
wire [8:0] int_index_step = int_step[0] ? int_index1 : int_index0;
wire int_step_ram = !int_index_step[8] && (!int_step[0] || txn_word);
// A word whose two bytes share a row goes through the port in one step: a
// write is then done the next clock, a read the clock after (registered).
// At 16 MHz an enable can come five clocks after the request, and a bank
// switch's engine may hold the port for two of them.
wire int_same_row = txn_word && (int_index0[8:4] == int_index1[8:4]);
wire int_pair = int_step == 2'd0 && int_same_row && !int_index1[8];
wire [1:0] int_next_step = (int_step == 2'd0 && txn_word && !int_same_row) ?
                           2'd1 : (txn_write ? 2'd3 : 2'd2);
wire int_done = int_step == 2'd3;

function automatic [15:0] arch_bank_word;
    input [3:0] word_index;
    begin
        case (word_index)
            4'h4: arch_bank_word = arch_ds;
            4'h5: arch_bank_word = arch_ss;
            4'h6: arch_bank_word = arch_cs;
            4'h7: arch_bank_word = arch_es;
            4'h8: arch_bank_word = arch_di;
            4'h9: arch_bank_word = arch_si;
            4'ha: arch_bank_word = arch_bp;
            4'hb: arch_bank_word = arch_sp;
            4'hc: arch_bank_word = arch_bx;
            4'hd: arch_bank_word = arch_dx;
            4'he: arch_bank_word = arch_cx;
            default: arch_bank_word = arch_ax;
        endcase
    end
endfunction

// The active bank's registers live in the CPU; a read of their bytes returns
// the live value, every other internal RAM byte the stored one.
function automatic [7:0] internal_read_byte;
    input [8:0] index;
    input [7:0] ram_byte;
    reg [15:0] word_value;
    begin
        if (!index[8]) begin
            if (index[7:5] == active_bank && index[4:3] != 2'b00) begin
                word_value = arch_bank_word(index[4:1]);
                internal_read_byte = index[0] ? word_value[15:8] :
                                                word_value[7:0];
            end else begin
                internal_read_byte = ram_byte;
            end
        end else begin
            case (index)
                9'h100: internal_read_byte = (p0_latch & ~pm0_reg) |
                                                   (port0_in & pm0_reg);
                9'h108: internal_read_byte = (p1_latch & ~pm1_reg) |
                                                   (port1_in & pm1_reg);
                9'h110: internal_read_byte = p2_latch & ~pm2_reg;
                9'h138: internal_read_byte = portt_in;
                9'h180: internal_read_byte = 8'hff;
                9'h181: internal_read_byte = 8'hff;
                9'h18a: internal_read_byte = md1_reg[7:0];
                9'h18b: internal_read_byte = md1_reg[15:8];
                9'h190: internal_read_byte = tmc0_reg;
                9'h191: internal_read_byte = tmc1_reg;
                9'h19c: internal_read_byte = tmic0_reg;
                9'h19d: internal_read_byte = tmic1_reg;
                9'h19e: internal_read_byte = {timer2_pending, tmic2_reg[6:0]};
                9'h1e1: internal_read_byte = rfm_reg;
                9'h1e8: internal_read_byte = wtc_lo;
                9'h1e9: internal_read_byte = wtc_hi;
                9'h1eb: internal_read_byte = prc_reg;
                9'h1fc: internal_read_byte = ispr_reg;
                9'h1ff: internal_read_byte = idb_reg;
                default: internal_read_byte = 8'h00;
            endcase
        end
    end
endfunction

function automatic internal_selected;
    input [19:0] address;
    input        data_access;
    begin
        internal_selected = data_access &&
            ((((address & 20'hffe00) == {idb_reg, 12'he00}) &&
              (ramen || address[8])) || address == 20'hfffff);
    end
endfunction

function automatic [31:0] timer_period;
    input [15:0] md_value;
    input [7:0]  control;
    input [7:0]  prc_value;
    reg [31:0] md_extended;
    reg [31:0] md_times_3;
    begin
        md_extended = {16'd0, md_value};
        md_times_3 = md_extended + (md_extended << 1);
        if (control[6]) begin
            case (prc_value[1:0])
                2'b00: timer_period = md_extended << 8;
                2'b01: timer_period = md_extended << 9;
                default: timer_period = md_extended << 10;
            endcase
        end else begin
            case (prc_value[1:0])
                2'b00: timer_period = md_times_3 << 2;
                2'b01: timer_period = md_times_3 << 3;
                default: timer_period = md_times_3 << 4;
            endcase
        end
    end
endfunction

function automatic [15:0] packed_psw;
    input [15:0] flags_value;
    input [2:0]  bank;
    begin
        packed_psw = {1'b1, bank, flags_value[11:2], 1'b1, flags_value[0]};
    end
endfunction

function automatic [15:0] gpr16_read;
    input [2:0] code;
    begin
        case (code)
            3'd0: gpr16_read = arch_ax;
            3'd1: gpr16_read = arch_cx;
            3'd2: gpr16_read = arch_dx;
            3'd3: gpr16_read = arch_bx;
            3'd4: gpr16_read = arch_sp;
            3'd5: gpr16_read = arch_bp;
            3'd6: gpr16_read = arch_si;
            default: gpr16_read = arch_di;
        endcase
    end
endfunction

function automatic [7:0] gpr8_read;
    input [2:0] code;
    begin
        case (code)
            3'd0: gpr8_read = arch_ax[7:0];
            3'd1: gpr8_read = arch_cx[7:0];
            3'd2: gpr8_read = arch_dx[7:0];
            3'd3: gpr8_read = arch_bx[7:0];
            3'd4: gpr8_read = arch_ax[15:8];
            3'd5: gpr8_read = arch_cx[15:8];
            3'd6: gpr8_read = arch_dx[15:8];
            default: gpr8_read = arch_bx[15:8];
        endcase
    end
endfunction

function automatic [15:0] ea_base;
    input [2:0] code;
    begin
        case (code)
            3'd0: ea_base = arch_bx + arch_si;
            3'd1: ea_base = arch_bx + arch_di;
            3'd2: ea_base = arch_bp + arch_si;
            3'd3: ea_base = arch_bp + arch_di;
            3'd4: ea_base = arch_si;
            3'd5: ea_base = arch_di;
            3'd6: ea_base = escape_modrm[7:6] == 2'b00 ? 16'h0000 : arch_bp;
            default: ea_base = arch_bx;
        endcase
    end
endfunction

function automatic ea_defaults_ss;
    input [2:0] code;
    begin
        ea_defaults_ss = code == 3'd2 || code == 3'd3 ||
                         (code == 3'd6 && escape_modrm[7:6] != 2'b00);
    end
endfunction

wire escape_is_word = escape_opcode[0];
wire escape_test = escape_opcode == 8'h10 || escape_opcode == 8'h11 ||
                   escape_opcode == 8'h18 || escape_opcode == 8'h19;
wire escape_clear = escape_opcode == 8'h12 || escape_opcode == 8'h13 ||
                    escape_opcode == 8'h1a || escape_opcode == 8'h1b;
wire escape_set = escape_opcode == 8'h14 || escape_opcode == 8'h15 ||
                  escape_opcode == 8'h1c || escape_opcode == 8'h1d;
wire escape_toggle = escape_opcode == 8'h16 || escape_opcode == 8'h17 ||
                     escape_opcode == 8'h1e || escape_opcode == 8'h1f;
wire [15:0] escape_register_value = escape_is_word ?
                                      gpr16_read(escape_modrm[2:0]) :
                                      {8'h00, gpr8_read(escape_modrm[2:0])};
wire [15:0] escape_bit_mask = 16'h0001 << escape_bit;

task automatic capture_arch_stage;
    begin
        arch_stage_ds <= arch_ds;
        arch_stage_ss <= arch_ss;
        arch_stage_cs <= arch_cs;
        arch_stage_es <= arch_es;
        arch_stage_di <= arch_di;
        arch_stage_si <= arch_si;
        arch_stage_bp <= arch_bp;
        arch_stage_sp <= arch_sp;
        arch_stage_bx <= arch_bx;
        arch_stage_dx <= arch_dx;
        arch_stage_cx <= arch_cx;
        arch_stage_ax <= arch_ax;
    end
endtask

// With vector_ip the new IP is the target bank's vector PC (offset 02),
// read by the engine; otherwise next_ip.
task automatic stage_bank_switch;
    input        write_return;
    input [2:0]  return_bank;
    input [15:0] return_psw;
    input [15:0] return_ip_value;
    input        vector_ip;
    input [15:0] next_ip;
    input [15:0] next_flags;
    begin
        capture_arch_stage();
        bank_commit_pending <= 1'b1;
        bank_commit_write_return <= write_return;
        bank_commit_source <= active_bank;
        bank_commit_target <= return_bank;
        bank_commit_psw <= return_psw;
        bank_commit_ip <= return_ip_value;
        load_prepare_pending <= 1'b1;
        load_prepare_mode <= LOAD_PREP_BANK;
        load_prepare_bank <= return_bank;
        load_prepare_target_was_active <= return_bank == active_bank;
        load_prepare_vector <= vector_ip;
        load_prepare_ip <= next_ip;
        load_prepare_flags <= next_flags;
    end
endtask

task automatic stage_register_load;
    input [15:0] value;
    input [15:0] next_flags;
    begin
        capture_arch_stage();
        load_prepare_pending <= 1'b1;
        load_prepare_mode <= LOAD_PREP_REGISTER;
        load_prepare_vector <= 1'b0;
        load_prepare_word <= escape_is_word;
        load_prepare_register <= escape_modrm[2:0];
        load_prepare_value <= value;
        load_prepare_ip <= arch_next_ip;
        load_prepare_flags <= next_flags;
    end
endtask

task automatic stage_push_load;
    input [15:0] next_sp;
    begin
        capture_arch_stage();
        load_prepare_pending <= 1'b1;
        load_prepare_mode <= LOAD_PREP_PUSH;
        load_prepare_vector <= 1'b0;
        load_prepare_value <= next_sp;
        load_prepare_ip <= arch_next_ip;
        load_prepare_flags <= arch_flags;
    end
endtask

task automatic stage_stack_load;
    input [2:0] bank;
    begin
        capture_arch_stage();
        load_prepare_pending <= 1'b1;
        load_prepare_mode <= LOAD_PREP_STACK;
        load_prepare_vector <= 1'b0;
        load_prepare_bank <= bank;
        load_prepare_target_was_active <= bank == active_bank;
        load_prepare_ip <= arch_next_ip;
        load_prepare_flags <= arch_flags;
    end
endtask

// Special function registers only; internal RAM bytes go through the RAM
// port (int_step).
task automatic apply_internal_write;
    input [8:0] index;
    input [7:0] value;
    begin
        if (index[8]) begin
            case (index)
                9'h100: p0_latch <= value;
                9'h101: pm0_reg <= value;
                9'h108: p1_latch <= value;
                9'h109: pm1_reg <= value;
                9'h110: p2_latch <= value;
                9'h111: pm2_reg <= value;
                9'h13b: pmt_reg <= value;
                9'h18a: md1_reg[7:0] <= value;
                9'h18b: md1_reg[15:8] <= value;
                9'h190: tmc0_reg <= value;
                9'h191: begin
                    tmc1_reg <= value & 8'hc0;
                    timer_count <= timer_period(md1_reg, value, prc_reg);
                end
                9'h19c: tmic0_reg <= value & 8'hd7;
                9'h19d: tmic1_reg <= value & 8'hd7;
                9'h19e: begin
                    tmic2_reg <= value & 8'hd7;
                    timer2_pending <= value[7];
                end
                9'h1e1: rfm_reg <= value;
                9'h1e8: wtc_lo <= value;
                9'h1e9: wtc_hi <= value;
                9'h1eb: begin
                    prc_reg <= value;
                    ramen <= value[6];
                end
                9'h1ff: idb_reg <= value;
                default: ;
            endcase
        end
    end
endtask

// Internal RAM port. Priority: reset clear, bank-switch engine, bus access,
// then the background read of the active bank's row A.
always @(*) begin
    iram_waddr = 4'd0;
    iram_be = 16'h0000;
    iram_wdata = 128'd0;
    iram_raddr = {active_bank, 1'b0};
    if (clr_busy) begin
        // The reset state: zero, but bank 7's CS (offset 0c) ffff.
        iram_waddr = clr_cnt[3:0];
        iram_be = 16'hffff;
        iram_wdata = clr_cnt[3:0] == 4'he ? {16'h0000, 16'hffff, 96'd0} :
                                            128'd0;
    end else if (eng_ram) begin
        case (eng_step)
            2'd0: begin
                iram_raddr = {load_prepare_bank, 1'b0};
                if (bank_commit_pending) begin
                    iram_waddr = {bank_commit_source, 1'b1};
                    iram_be = 16'hffff;
                    iram_wdata = {arch_stage_ax, arch_stage_cx,
                                  arch_stage_dx, arch_stage_bx,
                                  arch_stage_sp, arch_stage_bp,
                                  arch_stage_si, arch_stage_di};
                end
            end
            2'd1: begin
                iram_raddr = {load_prepare_bank, 1'b1};
                if (bank_commit_pending) begin
                    iram_waddr = {bank_commit_source, 1'b0};
                    iram_be = 16'hff00;
                    iram_wdata = {arch_stage_es, arch_stage_cs,
                                  arch_stage_ss, arch_stage_ds, 64'd0};
                end
            end
            default: begin
                if (bank_commit_pending && bank_commit_write_return) begin
                    iram_waddr = {bank_commit_target, 1'b0};
                    iram_be = 16'h00f0;
                    iram_wdata = {64'd0, bank_commit_ip,
                                  bank_commit_psw, 32'd0};
                end
            end
        endcase
    end else if (int_go) begin
        iram_raddr = int_index_step[7:4];
        if (txn_write && int_step_ram) begin
            iram_waddr = int_index_step[7:4];
            iram_be = (16'h0001 << int_index_step[3:0]) |
                      (int_pair ? 16'h0001 << int_index1[3:0] : 16'h0000);
            if (int_pair)
                iram_wdata = int_index0[0] ? {8{txn_dout[7:0], txn_dout[15:8]}} :
                                             {8{txn_dout[15:8], txn_dout[7:0]}};
            else
                iram_wdata = {16{int_step[0] ? txn_dout[15:8] : txn_dout[7:0]}};
        end
    end
end

dogyuun_v25_iram u_iram (
    .clk   (clk),
    .raddr (iram_raddr),
    .waddr (iram_waddr),
    .be    (iram_be),
    .wdata (iram_wdata),
    .q     (iram_q)
);

always @(posedge clk) begin
    clr_reset_n_d <= reset_n;
    if (!reset_n && clr_reset_n_d)
        clr_cnt <= 5'd0;
    else if (clr_busy)
        clr_cnt <= clr_cnt + 5'd1;

    iram_we_d <= iram_we;
    rd_tag <= RD_NONE;
    if (!clr_busy && !eng_ram) begin
        if (int_go)
            rd_tag <= int_step[0] ? RD_BUS1 : RD_BUS0;
        else if (bus_state != BUS_INTERNAL)
            rd_tag <= RD_REF;
    end
    ref_bank <= active_bank;

    case (rd_tag)
        RD_BUS0: begin
            int_rd0 <= iram_q[int_index0[3:0] * 8 +: 8];
            if (int_same_row)
                int_rd1 <= iram_q[int_index1[3:0] * 8 +: 8];
        end
        RD_BUS1: int_rd1 <= iram_q[int_index1[3:0] * 8 +: 8];
        default: ;
    endcase

    if (!reset_n || iram_we || iram_we_d) begin
        psw_valid <= 1'b0;
    end else if (rd_tag == RD_REF) begin
        psw_cache <= iram_q[63:32];
        psw_bank <= ref_bank;
        psw_valid <= 1'b1;
    end
end

dogyuun_z8086 u_cpu (
    .clk                    (clk),
    .clock_enable           (cpu_clock_enable),
    .reset_n                (reset_n),
    .addr                   (cpu_addr),
    .din                    (cpu_din),
    .dout                   (cpu_dout),
    .wr                     (cpu_wr),
    .rd                     (cpu_rd),
    .io                     (cpu_io),
    .word                   (cpu_word),
    .data_cycle             (cpu_data_cycle),
    .ready                  (cpu_ready),
    .intr                   (1'b0),
    .nmi                    (1'b0),
    .inta                   (),
    .secure_mode            (secure_mode),
    .fetch_hold             (base_fetch_hold),
    .instruction_start_hold (base_instruction_start_hold),
    .arch_load              (cpu_arch_load),
    .arch_load_ax           (load_ax),
    .arch_load_cx           (load_cx),
    .arch_load_dx           (load_dx),
    .arch_load_bx           (load_bx),
    .arch_load_sp           (load_sp),
    .arch_load_bp           (load_bp),
    .arch_load_si           (load_si),
    .arch_load_di           (load_di),
    .arch_load_cs           (load_cs),
    .arch_load_ds           (load_ds),
    .arch_load_es           (load_es),
    .arch_load_ss           (load_ss),
    .arch_load_ip           (load_ip),
    .arch_load_flags        (load_flags),
    .arch_load_halted       (1'b0),
    .arch_flags_write       (base_flags_write),
    .arch_flags_in          (commit_flags),
    .arch_ax                (arch_ax),
    .arch_cx                (arch_cx),
    .arch_dx                (arch_dx),
    .arch_bx                (arch_bx),
    .arch_sp                (arch_sp),
    .arch_bp                (arch_bp),
    .arch_si                (arch_si),
    .arch_di                (arch_di),
    .arch_cs                (arch_cs),
    .arch_ds                (arch_ds),
    .arch_es                (arch_es),
    .arch_ss                (arch_ss),
    .arch_next_ip           (arch_next_ip),
    .arch_flags             (arch_flags),
    .arch_halted            (arch_halted),
    .arch_segment_override  (arch_segment_override),
    .arch_override_segment  (arch_override_segment),
    .instruction_done       (instruction_done),
    .instruction_opcode     (instruction_opcode),
    .instruction_idle       (instruction_idle),
    .interrupt_deferred     (interrupt_deferred),
    .v25_escape_active      (escape_active),
    .v25_escape_lead        (escape_lead),
    .v25_escape_byte        (escape_byte),
    .v25_escape_byte_valid  (escape_byte_valid),
    .v25_escape_pop         (escape_pop),
    .v25_escape_complete    (escape_complete)
);

// Convert the compact core's 16-bit bus into the byte bus used by the sound
// subsystem. External transfer phases consume V25 clocks; the shared RAM is
// synchronous in the faster system domain and is therefore settled in time.
always @(posedge clk) begin
    if (!reset_n) begin
        bus_state <= BUS_IDLE;
        bus_wait_phase <= 5'd1;
        txn_ext <= 1'b0;
        txn_write <= 1'b0;
        txn_word <= 1'b0;
        txn_io <= 1'b0;
        txn_internal <= 1'b0;
        txn_phase <= 1'b0;
        txn_addr <= 20'h00000;
        txn_dout <= 16'h0000;
        txn_din <= 16'h0000;
        cpu_din <= 16'h0000;
        int_step <= 2'd0;
    end else begin
        case (bus_state)
            BUS_IDLE: begin
                txn_phase <= 1'b0;
                int_step <= 2'd0;
                if (ext_req) begin
                    txn_ext <= 1'b1;
                    txn_write <= ext_write;
                    txn_word <= ext_word;
                    txn_io <= 1'b0;
                    txn_addr <= ext_addr;
                    txn_dout <= ext_dout;
                    txn_internal <= internal_selected(ext_addr, 1'b1);
                    bus_wait_phase <= 5'd1;
                    bus_state <= internal_selected(ext_addr, 1'b1) ?
                                 BUS_INTERNAL : BUS_EXT_WAIT1;
                end else if (cpu_rd || cpu_wr) begin
                    txn_ext <= 1'b0;
                    txn_write <= cpu_wr;
                    txn_word <= cpu_word;
                    txn_io <= cpu_io;
                    txn_addr <= cpu_addr;
                    txn_dout <= cpu_dout;
                    txn_internal <= !cpu_io &&
                                    internal_selected(cpu_addr, cpu_data_cycle);
                    bus_wait_phase <= 5'd1;
                    bus_state <= (!cpu_io &&
                                  internal_selected(cpu_addr, cpu_data_cycle)) ?
                                 BUS_INTERNAL : BUS_EXT_WAIT1;
                end
            end
            BUS_INTERNAL: begin
                // Byte 0 then byte 1 through the RAM port, one clock each
                // (one for both in a row); done before the V25's next enable.
                if (int_go)
                    int_step <= int_next_step;
                else if (int_step == 2'd2)
                    int_step <= 2'd3;
                if (int_done && bus_phase_advance) begin
                    if (!txn_write) begin
                        txn_din[7:0] <= internal_read_byte(int_index0, int_rd0);
                        txn_din[15:8] <= txn_word ?
                            internal_read_byte(int_index1, int_rd1) : 8'h00;
                        cpu_din[7:0] <= internal_read_byte(int_index0, int_rd0);
                        cpu_din[15:8] <= txn_word ?
                            internal_read_byte(int_index1, int_rd1) : 8'h00;
                    end
                    bus_state <= txn_ext ? BUS_ACK_EXT : BUS_ACK_CPU;
                end
            end
            BUS_EXT_WAIT1: begin
                if (bus_phase_advance) begin
                    if (bus_wait_phase < txn_byte_phases - 1'b1) begin
                        bus_wait_phase <= bus_wait_phase + 5'd1;
                    end else begin
                        if (!txn_write) begin
                            if (txn_phase)
                                txn_din[15:8] <= bus_din;
                            else begin
                                txn_din[7:0] <= bus_din;
                                cpu_din[7:0] <= bus_din;
                            end
                        end
                        bus_state <= BUS_EXT_GAP;
                    end
                end
            end
            BUS_EXT_GAP: begin
                if (bus_phase_advance) begin
                    if (txn_word && !txn_phase) begin
                        txn_phase <= 1'b1;
                        bus_wait_phase <= 5'd1;
                        bus_state <= BUS_EXT_WAIT1;
                    end else begin
                        if (!txn_write && txn_word)
                            cpu_din <= txn_din;
                        bus_state <= txn_ext ? BUS_ACK_EXT : BUS_ACK_CPU;
                    end
                end
            end
            BUS_ACK_CPU: begin
                if (clock_enable)
                    bus_state <= BUS_DROP_CPU;
            end
            BUS_DROP_CPU: begin
                if (!cpu_rd && !cpu_wr)
                    bus_state <= BUS_IDLE;
            end
            BUS_ACK_EXT: begin
                if (clock_enable)
                    bus_state <= BUS_DROP_EXT;
            end
            BUS_DROP_EXT: begin
                if (!ext_req)
                    bus_state <= BUS_IDLE;
            end
            default: bus_state <= BUS_IDLE;
        endcase
    end
end

reg [2:0] target_bank;
reg [15:0] saved_psw;
reg [15:0] return_ip;
reg [15:0] operation_value;
reg [15:0] operation_result;
reg [4:0] operation_count;
reg [15:0] data_segment;

// V25 extension controller, register banks, SFR writes, and timer.
always @(posedge clk) begin
    if (!reset_n) begin
        active_bank <= 3'd7;
        bank_commit_pending <= 1'b0;
        bank_commit_write_return <= 1'b0;
        bank_commit_source <= 3'd0;
        bank_commit_target <= 3'd0;
        bank_commit_psw <= 16'h0000;
        bank_commit_ip <= 16'h0000;
        arch_stage_ds <= 16'h0000;
        arch_stage_ss <= 16'h0000;
        arch_stage_cs <= 16'h0000;
        arch_stage_es <= 16'h0000;
        arch_stage_di <= 16'h0000;
        arch_stage_si <= 16'h0000;
        arch_stage_bp <= 16'h0000;
        arch_stage_sp <= 16'h0000;
        arch_stage_bx <= 16'h0000;
        arch_stage_dx <= 16'h0000;
        arch_stage_cx <= 16'h0000;
        arch_stage_ax <= 16'h0000;
        load_prepare_pending <= 1'b0;
        load_prepare_mode <= LOAD_PREP_NONE;
        load_prepare_bank <= 3'd0;
        load_prepare_target_was_active <= 1'b0;
        load_prepare_vector <= 1'b0;
        load_prepare_word <= 1'b0;
        eng_step <= 2'd0;
        load_prepare_register <= 3'd0;
        load_prepare_value <= 16'h0000;
        load_prepare_ip <= 16'h0000;
        load_prepare_flags <= 16'h0000;
        idb_reg <= 8'hff;
        ramen <= 1'b1;
        prc_reg <= 8'h4e;
        p0_latch <= 8'h00;
        p1_latch <= 8'h00;
        p2_latch <= 8'h00;
        pm0_reg <= 8'hff;
        pm1_reg <= 8'hff;
        pm2_reg <= 8'hff;
        pmt_reg <= 8'h00;
        rfm_reg <= 8'hfc;
        wtc_lo <= 8'hff;
        wtc_hi <= 8'hff;
        md1_reg <= 16'h0000;
        tmc0_reg <= 8'h00;
        tmc1_reg <= 8'h00;
        tmic0_reg <= 8'h47;
        tmic1_reg <= 8'h47;
        tmic2_reg <= 8'h47;
        ispr_reg <= 8'h00;
        timer_count <= 32'd0;
        timer2_pending <= 1'b0;
        irq_entry_pending <= 1'b0;
        escape_state <= ESC_IDLE;
        escape_delay_count <= 5'd0;
        instruction_gap_count <= 5'd0;
        escape_timing_profile <= 1'b0;
        escape_opcode <= 8'h00;
        escape_modrm <= 8'h00;
        escape_disp <= 16'h0000;
        escape_imm <= 8'h00;
        escape_bit <= 4'd0;
        escape_mem_value <= 16'h0000;
        commit_flags <= 16'h0002;
        fault_latch <= 1'b0;
        load_ax <= 16'h0000;
        load_cx <= 16'h0000;
        load_dx <= 16'h0000;
        load_bx <= 16'h0000;
        load_sp <= 16'h0000;
        load_bp <= 16'h0000;
        load_si <= 16'h0000;
        load_di <= 16'h0000;
        load_cs <= 16'hffff;
        load_ds <= 16'h0000;
        load_es <= 16'h0000;
        load_ss <= 16'h0000;
        load_ip <= 16'h0000;
        load_flags <= 16'hf002;
        ext_req <= 1'b0;
        ext_write <= 1'b0;
        ext_word <= 1'b0;
        ext_addr <= 20'h00000;
        ext_dout <= 16'h0000;
    end else begin
        // Engine step 0 loads what the staged registers give, as one clock
        // did before; a bank switch or MOVSPB then takes the target bank's
        // rows A and B from the RAM reads issued in steps 0 and 1.
        if (load_prepare_pending) begin
            case (eng_step)
                2'd0: begin
                    load_ax <= arch_stage_ax;
                    load_cx <= arch_stage_cx;
                    load_dx <= arch_stage_dx;
                    load_bx <= arch_stage_bx;
                    load_sp <= arch_stage_sp;
                    load_bp <= arch_stage_bp;
                    load_si <= arch_stage_si;
                    load_di <= arch_stage_di;
                    load_cs <= arch_stage_cs;
                    load_ds <= arch_stage_ds;
                    load_es <= arch_stage_es;
                    load_ss <= arch_stage_ss;
                    load_ip <= load_prepare_ip;
                    load_flags <= load_prepare_flags;

                    case (load_prepare_mode)
                        LOAD_PREP_REGISTER: begin
                            if (load_prepare_word) begin
                                case (load_prepare_register)
                                    3'd0: load_ax <= load_prepare_value;
                                    3'd1: load_cx <= load_prepare_value;
                                    3'd2: load_dx <= load_prepare_value;
                                    3'd3: load_bx <= load_prepare_value;
                                    3'd4: load_sp <= load_prepare_value;
                                    3'd5: load_bp <= load_prepare_value;
                                    3'd6: load_si <= load_prepare_value;
                                    3'd7: load_di <= load_prepare_value;
                                endcase
                            end else begin
                                case (load_prepare_register)
                                    3'd0: load_ax <= {
                                        arch_stage_ax[15:8],
                                        load_prepare_value[7:0]
                                    };
                                    3'd1: load_cx <= {
                                        arch_stage_cx[15:8],
                                        load_prepare_value[7:0]
                                    };
                                    3'd2: load_dx <= {
                                        arch_stage_dx[15:8],
                                        load_prepare_value[7:0]
                                    };
                                    3'd3: load_bx <= {
                                        arch_stage_bx[15:8],
                                        load_prepare_value[7:0]
                                    };
                                    3'd4: load_ax <= {
                                        load_prepare_value[7:0],
                                        arch_stage_ax[7:0]
                                    };
                                    3'd5: load_cx <= {
                                        load_prepare_value[7:0],
                                        arch_stage_cx[7:0]
                                    };
                                    3'd6: load_dx <= {
                                        load_prepare_value[7:0],
                                        arch_stage_dx[7:0]
                                    };
                                    3'd7: load_bx <= {
                                        load_prepare_value[7:0],
                                        arch_stage_bx[7:0]
                                    };
                                endcase
                            end
                        end

                        LOAD_PREP_PUSH:
                            load_sp <= load_prepare_value;

                        default: ;
                    endcase

                    if (eng_ram) begin
                        eng_step <= 2'd1;
                    end else begin
                        load_prepare_pending <= 1'b0;
                        load_prepare_mode <= LOAD_PREP_NONE;
                    end
                end

                2'd1: begin
                    // Row A of the target bank.
                    if (!load_prepare_target_was_active) begin
                        if (load_prepare_mode == LOAD_PREP_BANK)
                            {load_es, load_cs, load_ss, load_ds} <=
                                iram_q[127:64];
                        else
                            load_ss <= iram_q[95:80];
                    end
                    if (load_prepare_vector)
                        load_ip <= iram_q[31:16];
                    eng_step <= 2'd2;
                end

                default: begin
                    // Row B of the target bank; the return PSW and PC are
                    // written this clock.
                    if (!load_prepare_target_was_active) begin
                        if (load_prepare_mode == LOAD_PREP_BANK)
                            {load_ax, load_cx, load_dx, load_bx,
                             load_sp, load_bp, load_si, load_di} <= iram_q;
                        else
                            load_sp <= iram_q[63:48];
                    end
                    eng_step <= 2'd0;
                    bank_commit_pending <= 1'b0;
                    bank_commit_write_return <= 1'b0;
                    load_prepare_pending <= 1'b0;
                    load_prepare_mode <= LOAD_PREP_NONE;
                end
            endcase
        end

        if (clock_enable && tmc1_reg[7] && md1_reg != 16'h0000) begin
            if (timer_count <= 32'd1) begin
                timer_count <= timer_period(md1_reg, tmc1_reg, prc_reg);
                timer2_pending <= 1'b1;
            end else begin
                timer_count <= timer_count - 32'd1;
            end
        end

        if (clock_enable) begin
            if (instruction_gap_start)
                instruction_gap_count <= instruction_gap_load;
            else if (instruction_gap_count != 5'd0)
                instruction_gap_count <= instruction_gap_count - 5'd1;
        end

        if (int_write0)
            apply_internal_write(int_index0, txn_dout[7:0]);
        if (int_write1)
            apply_internal_write(int_index1, txn_dout[15:8]);

        if (clock_enable) begin
            // A request may become pending while BRKCS is draining. Do not
            // carry that latch into the banked handler after its load clears
            // IF; the hardware leaves the timer pending and services it once
            // RETRBI restores an interruptible PSW.
            if (!timer2_irq_request)
                irq_entry_pending <= 1'b0;
            else if (!irq_entry_pending)
                irq_entry_pending <= 1'b1;

            if (escape_delay_count != 5'd0) begin
                escape_delay_count <= escape_delay_count - 5'd1;
            end else case (escape_state)
                ESC_IDLE: begin
                    if (escape_active) begin
                        escape_timing_profile <=
                            instruction_timing_profile_active;
                        if (escape_lead == 8'h0f) begin
                            escape_state <= ESC_OPCODE;
                        end else begin
                            escape_opcode <= escape_lead;
                            escape_disp <= 16'h0000;
                            if (escape_lead == 8'h68)
                                escape_state <= ESC_DISP_LO;
                            else if (escape_lead == 8'h6a)
                                escape_state <= ESC_IMMEDIATE;
                            else
                                escape_state <= ESC_MODRM;
                        end
                    end else if (irq_entry_pending &&
                                 timer2_irq_request &&
                                 irq_entry_safe) begin
                        target_bank = tmic0_reg[2:0];
                        saved_psw = packed_psw(arch_flags, active_bank);
                        stage_bank_switch(
                            1'b1,
                            target_bank,
                            saved_psw,
                            arch_next_ip,
                            1'b1,
                            16'h0000,
                            (saved_psw & 16'hfcff & 16'h8fff) |
                            {1'b0, target_bank, 12'h000}
                        );
                        active_bank <= target_bank;
                        ispr_reg[target_bank] <= 1'b1;
                        timer2_pending <= 1'b0;
                        irq_entry_pending <= 1'b0;
                        escape_state <= ESC_LOAD_COMMIT;
                    end
                end

                ESC_OPCODE: begin
                    if (escape_byte_valid) begin
                        escape_opcode <= escape_byte;
                        if ((escape_byte >= 8'h10 && escape_byte <= 8'h1f) ||
                            escape_byte == 8'h2d)
                            escape_state <= ESC_MODRM;
                        else if (escape_byte == 8'h25 ||
                                 escape_byte == 8'h91 ||
                                 escape_byte == 8'h92)
                            escape_state <= ESC_PREPARE;
                        else
                            escape_state <= ESC_FAULT_COMMIT;
                    end
                end

                ESC_MODRM: begin
                    if (escape_byte_valid) begin
                        escape_modrm <= escape_byte;
                        escape_disp <= 16'h0000;
                        if (escape_opcode == 8'h2d)
                            escape_state <= ESC_PREPARE;
                        else if (escape_byte[7:6] == 2'b01)
                            escape_state <= ESC_DISP8;
                        else if (escape_byte[7:6] == 2'b10 ||
                                 (escape_byte[7:6] == 2'b00 &&
                                  escape_byte[2:0] == 3'b110))
                            escape_state <= ESC_DISP_LO;
                        else if (escape_opcode >= 8'h18)
                            escape_state <= ESC_IMMEDIATE;
                        else
                            escape_state <= ESC_PREPARE;
                    end
                end

                ESC_DISP8: begin
                    if (escape_byte_valid) begin
                        escape_disp <= {{8{escape_byte[7]}}, escape_byte};
                        escape_state <= escape_opcode >= 8'h18 ?
                                        ESC_IMMEDIATE : ESC_PREPARE;
                    end
                end

                ESC_DISP_LO: begin
                    if (escape_byte_valid) begin
                        escape_disp[7:0] <= escape_byte;
                        escape_state <= ESC_DISP_HI;
                    end
                end

                ESC_DISP_HI: begin
                    if (escape_byte_valid) begin
                        escape_disp[15:8] <= escape_byte;
                        escape_state <= (escape_opcode >= 8'h18 &&
                                         escape_opcode != 8'h68) ?
                                        ESC_IMMEDIATE : ESC_PREPARE;
                    end
                end

                ESC_IMMEDIATE: begin
                    if (escape_byte_valid) begin
                        escape_imm <= escape_byte;
                        escape_bit <= escape_is_word ?
                                      escape_byte[3:0] : {1'b0, escape_byte[2:0]};
                        escape_state <= ESC_PREPARE;
                    end
                end

                ESC_PREPARE: begin
                    if (escape_opcode == 8'h68 || escape_opcode == 8'h6a) begin
                        stage_push_load(arch_sp - 16'd2);
                        ext_addr <= {arch_ss, 4'b0000} +
                                    {4'b0000, arch_sp - 16'd2};
                        ext_dout <= escape_opcode == 8'h68 ?
                                    escape_disp : {{8{escape_imm[7]}}, escape_imm};
                        ext_write <= 1'b1;
                        ext_word <= 1'b1;
                        ext_req <= 1'b1;
                        escape_state <= ESC_PUSH_WRITE;
                    end else if (escape_opcode == 8'hc0 || escape_opcode == 8'hc1) begin
                        if (escape_modrm[7:6] != 2'b11 ||
                            escape_modrm[5:3] > 3'd1) begin
                            escape_state <= ESC_FAULT_COMMIT;
                        end else begin
                            operation_value = escape_register_value;
                            operation_result = operation_value;
                            commit_flags = arch_flags;
                            operation_count = escape_is_word ?
                                              {1'b0, escape_imm[3:0]} :
                                              {2'b00, escape_imm[2:0]};

                            if (operation_count != 5'd0) begin
                                if (escape_modrm[5:3] == 3'd0) begin
                                    if (escape_is_word)
                                        operation_result =
                                            (operation_value << operation_count) |
                                            (operation_value >> (5'd16 - operation_count));
                                    else
                                        operation_result[7:0] =
                                            (operation_value[7:0] << operation_count) |
                                            (operation_value[7:0] >> (5'd8 - operation_count));
                                    commit_flags[0] = operation_result[0];
                                    if (operation_count == 5'd1)
                                        commit_flags[11] = escape_is_word ?
                                            operation_result[15] ^ operation_result[0] :
                                            operation_result[7] ^ operation_result[0];
                                end else begin
                                    if (escape_is_word)
                                        operation_result =
                                            (operation_value >> operation_count) |
                                            (operation_value << (5'd16 - operation_count));
                                    else
                                        operation_result[7:0] =
                                            (operation_value[7:0] >> operation_count) |
                                            (operation_value[7:0] << (5'd8 - operation_count));
                                    commit_flags[0] = escape_is_word ?
                                        operation_result[15] : operation_result[7];
                                    if (operation_count == 5'd1)
                                        commit_flags[11] = escape_is_word ?
                                            operation_result[15] ^ operation_result[14] :
                                            operation_result[7] ^ operation_result[6];
                                end
                            end

                            stage_register_load(
                                operation_result, commit_flags
                            );
                            escape_state <= ESC_LOAD_COMMIT;
                        end
                    end else if (escape_opcode == 8'h25) begin
                        // MOVSPB: the saved PSW (offset 04) comes from the
                        // background read; wait an enable if it is stale.
                        if (psw_ok) begin
                            saved_psw = psw_cache[15:0];
                            target_bank = saved_psw[14:12];
                            stage_stack_load(target_bank);
                            escape_state <= ESC_LOAD_COMMIT;
                        end
                    end else if (escape_opcode == 8'h91) begin
                        // RETRBI: saved PSW and PC (offsets 04, 06), likewise.
                        if (psw_ok) begin
                            saved_psw = psw_cache[15:0];
                            return_ip = psw_cache[31:16];
                            target_bank = saved_psw[14:12];
                            stage_bank_switch(
                                1'b0,
                                target_bank,
                                16'h0000,
                                16'h0000,
                                1'b0,
                                return_ip,
                                saved_psw
                            );
                            active_bank <= target_bank;
                            escape_state <= ESC_LOAD_COMMIT;
                        end
                    end else if (escape_opcode == 8'h92) begin
                        if (ispr_reg[0]) ispr_reg[0] <= 1'b0;
                        else if (ispr_reg[1]) ispr_reg[1] <= 1'b0;
                        else if (ispr_reg[2]) ispr_reg[2] <= 1'b0;
                        else if (ispr_reg[3]) ispr_reg[3] <= 1'b0;
                        else if (ispr_reg[4]) ispr_reg[4] <= 1'b0;
                        else if (ispr_reg[5]) ispr_reg[5] <= 1'b0;
                        else if (ispr_reg[6]) ispr_reg[6] <= 1'b0;
                        else if (ispr_reg[7]) ispr_reg[7] <= 1'b0;
                        // MAME's V20 timing is ten processor clocks here;
                        // the compact escape path supplies eleven half-clocks.
                        escape_delay_count <= 5'd9;
                        escape_state <= ESC_DONE_COMMIT;
                    end else if (escape_opcode == 8'h2d) begin
                        if (escape_modrm[7:6] != 2'b11) begin
                            escape_state <= ESC_FAULT_COMMIT;
                        end else begin
                            operation_value = gpr16_read(escape_modrm[2:0]);
                            target_bank = operation_value[2:0];
                            saved_psw = packed_psw(arch_flags, active_bank);
                            stage_bank_switch(
                                1'b1,
                                target_bank,
                                saved_psw,
                                arch_next_ip,
                                1'b1,
                                16'h0000,
                                (saved_psw & 16'h8cff) |
                                {1'b0, target_bank, 12'h000}
                            );
                            active_bank <= target_bank;
                            escape_state <= ESC_LOAD_COMMIT;
                        end
                    end else if (escape_opcode >= 8'h10 &&
                                 escape_opcode <= 8'h1f) begin
                        if (escape_opcode < 8'h18)
                            escape_bit <= escape_is_word ?
                                          arch_cx[3:0] : {1'b0, arch_cx[2:0]};
                        if (escape_modrm[7:6] == 2'b11) begin
                            operation_value = escape_register_value;
                            if (escape_test) begin
                                commit_flags = arch_flags;
                                commit_flags[11] = 1'b0;
                                commit_flags[0] = 1'b0;
                                commit_flags[6] =
                                    (operation_value & escape_bit_mask) == 16'h0000;
                                // Register TEST1 is 16 clocks with a CL bit
                                // index and 20 clocks with an immediate index.
                                escape_delay_count <=
                                    escape_opcode >= 8'h18 ?
                                    TEST1_IMMEDIATE_DELAY : 5'd11;
                                escape_state <= ESC_FLAGS_COMMIT;
                            end else begin
                                operation_result = operation_value;
                                if (escape_clear)
                                    operation_result = operation_value & ~escape_bit_mask;
                                else if (escape_set)
                                    operation_result = operation_value | escape_bit_mask;
                                else if (escape_toggle)
                                    operation_result = operation_value ^ escape_bit_mask;
                                stage_register_load(
                                    operation_result, arch_flags
                                );
                                escape_state <= ESC_LOAD_COMMIT;
                            end
                        end else begin
                            data_segment = arch_segment_override ?
                                           arch_override_segment :
                                           (ea_defaults_ss(escape_modrm[2:0]) ?
                                            arch_ss : arch_ds);
                            ext_addr <= {data_segment, 4'b0000} +
                                        {4'b0000,
                                         ea_base(escape_modrm[2:0]) + escape_disp};
                            ext_write <= 1'b0;
                            ext_word <= escape_is_word;
                            ext_req <= 1'b1;
                            escape_state <= ESC_MEM_READ;
                        end
                    end else begin
                        escape_state <= ESC_FAULT_COMMIT;
                    end
                end

                ESC_MEM_READ: begin
                    if (ext_ready) begin
                        ext_req <= 1'b0;
                        escape_mem_value <= ext_din;
                        if (escape_test) begin
                            commit_flags = arch_flags;
                            commit_flags[11] = 1'b0;
                            commit_flags[0] = 1'b0;
                            commit_flags[6] =
                                (ext_din & escape_bit_mask) == 16'h0000;
                            if (escape_timing_profile)
                                escape_delay_count <=
                                    escape_opcode >= 8'h18 ? 5'd18 : 5'd8;
                            else
                                escape_delay_count <= TEST1_MEMORY_DELAY;
                            escape_state <= ESC_FLAGS_COMMIT;
                        end else begin
                            operation_result = ext_din;
                            if (escape_clear)
                                operation_result = ext_din & ~escape_bit_mask;
                            else if (escape_set)
                                operation_result = ext_din | escape_bit_mask;
                            else if (escape_toggle)
                                operation_result = ext_din ^ escape_bit_mask;
                            ext_dout <= operation_result;
                            escape_state <= ESC_MEM_GAP;
                        end
                    end
                end

                ESC_MEM_GAP: begin
                    ext_write <= 1'b1;
                    ext_req <= 1'b1;
                    escape_state <= ESC_MEM_WRITE;
                end

                ESC_MEM_WRITE: begin
                    if (ext_ready) begin
                        ext_req <= 1'b0;
                        ext_write <= 1'b0;
                        if (escape_opcode == 8'h1a ||
                            escape_opcode == 8'h1b)
                            escape_delay_count <= 5'd6;
                        escape_state <= ESC_DONE_COMMIT;
                    end
                end

                ESC_PUSH_WRITE: begin
                    if (ext_ready) begin
                        ext_req <= 1'b0;
                        ext_write <= 1'b0;
                        escape_state <= ESC_LOAD_COMMIT;
                    end
                end

                ESC_FLAGS_COMMIT,
                ESC_DONE_COMMIT: begin
                    escape_state <= ESC_IDLE;
                end

                ESC_LOAD_COMMIT: begin
                    if (!load_prepare_pending)
                        escape_state <= ESC_IDLE;
                end

                ESC_FAULT_COMMIT: begin
                    fault_latch <= 1'b1;
                    escape_state <= ESC_IDLE;
                end

                default: begin
                    fault_latch <= 1'b1;
                    escape_state <= ESC_FAULT_COMMIT;
                end
            endcase
        end
    end
end

endmodule

// The internal RAM: 16 rows of 16 bytes, written a byte lane at a time,
// read one row a clock (registered address), one small RAM a lane. Quartus
// 21.1 puts each lane in its own M10K (16 blocks for 2 Kbit) and takes no
// ramstyle "MLAB" here, on the RAM or on the module.
module dogyuun_v25_iram (
    input              clk,
    input      [3:0]   raddr,
    input      [3:0]   waddr,
    input      [15:0]  be,
    input      [127:0] wdata,
    output     [127:0] q
);

genvar lane;
generate for (lane = 0; lane < 16; lane = lane + 1) begin : g_lane
    reg [7:0] ram [0:15];
    reg [7:0] lane_q;
    always @(posedge clk) begin
        if (be[lane])
            ram[waddr] <= wdata[lane*8 +: 8];
        lane_q <= ram[raddr];
    end
    assign q[lane*8 +: 8] = lane_q;
end endgenerate

endmodule

// The V25 wrapper against upstream's: both run the same program from the
// same shared-RAM traffic, and every bus signal and the PC must agree on
// every clock. dogyuun_v25_cpu_ref is upstream's wrapper as imported (its
// internal RAM in registers), renamed by the Makefile.
module tb_v25 (
    input              clk,
    input              reset_n,
    input      [7:0]   cen_num,     // V25 clock = 94.5 MHz x cen_num/189
    input              secure_mode, // 1: nitro (Dogyuun), 0: plain (Batsugun)
    input              dbg,
    // 68000 side of the shared RAM, replayed from MAME
    input              host_we,
    input      [14:0]  host_addr,
    input      [7:0]   host_data,

    output             mismatch,
    // both sides, for the report: {pc, addr, dout&doe, doe, rw, mreq_n,
    // mstb_n, iostb_n, halted, fault, idle}
    output     [55:0]  ref_state,
    output     [55:0]  dut_state,
    output     [19:0]  pc,
    output     [19:0]  bus_addr,
    output     [7:0]   bus_dout,
    output             bus_write,
    output reg [31:0]  bank_switches,
    output reg [31:0]  iram_bus_reads,
    output reg [31:0]  iram_bus_writes
);

// 25 for Dogyuun's 12.5 MHz, 32 for Batsugun's 16 MHz.
reg [7:0] cen_accum = 8'd0;
reg       cen = 1'b0;
always @(posedge clk) begin
    if (cen_accum >= 8'd189 - cen_num) begin
        cen_accum <= cen_accum + cen_num - 8'd189;
        cen <= 1'b1;
    end else begin
        cen_accum <= cen_accum + cen_num;
        cen <= 1'b0;
    end
end

wire [19:0] a_addr, b_addr;
wire [7:0]  a_dout, b_dout;
wire        a_doe, b_doe, a_rw, b_rw, a_mreq, b_mreq, a_mstb, b_mstb;
wire        a_iostb, b_iostb, a_halt, b_halt, a_fault, b_fault;
wire        a_idle, b_idle;
wire [19:0] a_pc, b_pc;
wire [7:0]  a_din, b_din;

// One shared RAM per side, read a clock late as on the board.
module_ram ram_a (
    .clk(clk), .host_we(host_we), .host_addr(host_addr),
    .host_data(host_data), .addr(a_addr), .dout(a_dout), .doe(a_doe),
    .rw(a_rw), .mreq_n(a_mreq), .mstb_n(a_mstb), .din(a_din));
module_ram ram_b (
    .clk(clk), .host_we(host_we), .host_addr(host_addr),
    .host_data(host_data), .addr(b_addr), .dout(b_dout), .doe(b_doe),
    .rw(b_rw), .mreq_n(b_mreq), .mstb_n(b_mstb), .din(b_din));

dogyuun_v25_cpu_ref u_ref (
    .clk (clk), .reset (!reset_n), .reset_n (reset_n), .clock_enable (cen),
    .port0_in (8'hff), .port1_in (8'h6f), .portt_in (8'hff),
    .bus_addr (a_addr), .bus_dout (a_dout), .bus_din (a_din),
    .bus_doe (a_doe), .bus_r_w (a_rw), .bus_mreq_n (a_mreq),
    .bus_mstb_n (a_mstb), .bus_iostb_n (a_iostb),
    .halted (a_halt), .fault (a_fault), .debug_pc (a_pc),
    .state_idle (a_idle),
    .ss_restore_enable (1'b0), .ss_restore_commit (1'b0), .ss_data (64'd0),
    .ss_addr (32'd0), .ss_select (8'd0), .ss_write (1'b0), .ss_read (1'b0),
    .ss_query (1'b0), .ss_data_out (), .ss_ack ()
);

dogyuun_v25_cpu u_dut (
    .clk (clk), .reset (!reset_n), .reset_n (reset_n), .clock_enable (cen),
    .secure_mode (secure_mode), .tp023 (1'b0),
    .port0_in (8'hff), .port1_in (8'h6f), .portt_in (8'hff),
    .bus_addr (b_addr), .bus_dout (b_dout), .bus_din (b_din),
    .bus_doe (b_doe), .bus_r_w (b_rw), .bus_mreq_n (b_mreq),
    .bus_mstb_n (b_mstb), .bus_iostb_n (b_iostb),
    .halted (b_halt), .fault (b_fault), .debug_pc (b_pc),
    .state_idle (b_idle)
);

assign mismatch = reset_n && (
    {a_addr, a_dout & {8{a_doe}}, a_doe, a_rw, a_mreq, a_mstb, a_iostb,
     a_halt, a_fault, a_pc, a_idle} !=
    {b_addr, b_dout & {8{b_doe}}, b_doe, b_rw, b_mreq, b_mstb, b_iostb,
     b_halt, b_fault, b_pc, b_idle});
assign ref_state = {a_pc, a_addr, a_dout & {8{a_doe}}, a_doe, a_rw, a_mreq,
                    a_mstb, a_iostb, a_halt, a_fault, a_idle};
assign dut_state = {b_pc, b_addr, b_dout & {8{b_doe}}, b_doe, b_rw, b_mreq,
                    b_mstb, b_iostb, b_halt, b_fault, b_idle};
assign pc = b_pc;
assign bus_addr = b_addr;
assign bus_dout = b_dout;
assign bus_write = !b_mreq && !b_mstb && !b_rw && b_doe;

always @(posedge clk) if (dbg)
    $display("ref idle %b ii %b bus %0d rd %b wr %b ext %b esc %0d ea %b so %b idf %b t2 %b iep %b bcp %b lpp %b | dut idle %b ii %b bus %0d rd %b wr %b ext %b esc %0d ea %b so %b idf %b t2 %b iep %b bcp %b lpp %b eng %0d",
        a_idle, u_ref.instruction_idle, u_ref.bus_state, u_ref.cpu_rd, u_ref.cpu_wr, u_ref.ext_req, u_ref.escape_state, u_ref.escape_active, u_ref.arch_segment_override, u_ref.interrupt_deferred, u_ref.timer2_irq_request, u_ref.irq_entry_pending, u_ref.bank_commit_pending, u_ref.load_prepare_pending,
        b_idle, u_dut.instruction_idle, u_dut.bus_state, u_dut.cpu_rd, u_dut.cpu_wr, u_dut.ext_req, u_dut.escape_state, u_dut.escape_active, u_dut.arch_segment_override, u_dut.interrupt_deferred, u_dut.timer2_irq_request, u_dut.irq_entry_pending, u_dut.bank_commit_pending, u_dut.load_prepare_pending, u_dut.eng_step);

// Coverage: register-bank switches and internal RAM accesses by the program.
reg bank_d = 1'b0;
reg int_d = 1'b0;
always @(posedge clk) begin
    bank_d <= u_dut.bank_commit_pending;
    int_d <= u_dut.bus_state == 4'd1;
    if (!reset_n) begin
        bank_switches <= 32'd0;
        iram_bus_reads <= 32'd0;
        iram_bus_writes <= 32'd0;
    end else begin
        if (u_dut.bank_commit_pending && !bank_d)
            bank_switches <= bank_switches + 32'd1;
        if (u_dut.bus_state == 4'd1 && !int_d && !u_dut.txn_addr[8]) begin
            if (u_dut.txn_write)
                iram_bus_writes <= iram_bus_writes + 32'd1;
            else
                iram_bus_reads <= iram_bus_reads + 32'd1;
        end
    end
end

endmodule

// The shared RAM as dogyuun_sound and dogyuun_main wire it: the V25 writes on
// the first clock of a write strobe, reads come back a clock late, the YM2151
// and OKI read as 00.
module module_ram (
    input             clk,
    input             host_we,
    input      [14:0] host_addr,
    input      [7:0]  host_data,
    input      [19:0] addr,
    input      [7:0]  dout,
    input             doe,
    input             rw,
    input             mreq_n,
    input             mstb_n,
    output     [7:0]  din
);
reg [7:0] mem [0:32767];
reg [7:0] q;
reg       write_d = 1'b0;
wire      active = !mreq_n && !mstb_n;
wire      write = active && !rw && doe;
always @(posedge clk) begin
    write_d <= write;
    if (host_we)
        mem[host_addr] <= host_data;
    else if (write && !write_d && addr[19])
        mem[addr[14:0]] <= dout;
    q <= mem[addr[14:0]];
end
assign din = (active && rw && addr[19]) ? q : 8'h00;
endmodule

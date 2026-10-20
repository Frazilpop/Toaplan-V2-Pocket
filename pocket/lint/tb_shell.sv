// SPDX-License-Identifier: GPL-3.0-or-later
// Toaplan V2 for Analogue Pocket — functional checks on the shell's servants.
//
//   - The loading path: APF bridge writes on clk_74a (one 32-bit word every
//     75 cycles, big-endian, as APF sends a data slot) through
//     pocket_rom_loader into the board's own loader (dogyuun_rom_loader),
//     whose SDRAM programming writes are acknowledged after a random wait.
//     Every word the board writes must be the image's word at the place the
//     region table says, the header must be accepted, nothing may overflow,
//     and rom_loaded must rise after "all complete" and drop ioctl_rom.
//   - pocket_video against the board's 432 x 262 raster on a /14 pixel
//     enable: one VS pulse per frame, one HS pulse per line, HS never within
//     3 cycles of VS, 240 lines of exactly 320 DE cycles, RGB zero outside DE.
//
// Run: pocket/lint/run_tb.sh [set.rom] (default build/pocket/batsugun.rom).
// The image's header and the first LOAD_BYTES of it are sent: the header
// and 64 KB of the 68000's program.

`timescale 1ns/1ps
`default_nettype none

// A dual-clock FIFO with dcfifo's ports and lpm_showahead "OFF" behaviour
// (q one read clock after rdreq), for data_loader. Crossing is not modelled.
module dcfifo #(
    parameter clocks_are_synchronized = "", parameter intended_device_family = "",
    parameter lpm_numwords = 4, parameter lpm_showahead = "", parameter lpm_type = "",
    parameter lpm_width = 1, parameter lpm_widthu = 2, parameter overflow_checking = "",
    parameter rdsync_delaypipe = 5, parameter underflow_checking = "", parameter use_eab = "",
    parameter wrsync_delaypipe = 5
)(
    input  wire [lpm_width-1:0] data,
    input  wire rdclk, rdreq, wrclk, wrreq, aclr,
    output reg  [lpm_width-1:0] q,
    output wire rdempty, rdfull, wrempty, wrfull, eccstatus,
    output wire [lpm_widthu-1:0] rdusedw, wrusedw
);
    reg [lpm_width-1:0] mem [0:63];
    integer wp = 0, rp = 0;
    assign rdempty = (wp == rp);
    always @(posedge wrclk) if (wrreq) begin
        if (wp - rp >= lpm_numwords) $fatal(1, "dcfifo overflow");
        mem[wp % 64] <= data; wp <= wp + 1;
    end
    always @(posedge rdclk) if (rdreq && wp != rp) begin
        q <= mem[rp % 64]; rp <= rp + 1;
    end
endmodule

module tb_shell;
    localparam int LOAD_BYTES = 32'h11000;
    localparam int AW = 22;

    reg clk_74a = 0, clk = 0;
    always #6.734 clk_74a = ~clk_74a;   // 74.25 MHz
    always #5.291 clk = ~clk;           // 94.5 MHz

    reg [7:0] img [0:LOAD_BYTES-1];
    reg [1023:0] path;
    integer fd, i;

    // ------------------------------------------------------- the shell side
    reg         bridge_wr = 0;
    reg  [31:0] bridge_addr = 0, bridge_wr_data = 0;
    reg         rst = 1, allcomplete = 0;
    wire        ioctl_rom, ioctl_wr;
    wire [26:0] ioctl_addr;
    wire [7:0]  ioctl_dout;
    wire        rom_loaded, overflow;
    wire [26:0] bytes;
    wire        prog_we;

    pocket_rom_loader u_loader (
        .clk_74a(clk_74a), .bridge_wr(bridge_wr), .bridge_endian_little(1'b0),
        .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .clk(clk), .rst(rst), .allcomplete_s(allcomplete),
        .ioctl_rom(ioctl_rom), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout), .prog_we(prog_we),
        .rom_loaded(rom_loaded), .bytes(bytes), .overflow(overflow)
    );

    // ------------------------------------------------------- the board side
    wire        dwnld_busy, prog_rd, cfg_valid, range_error, overflow_error;
    wire [1:0]  prog_ba, prog_mask;
    wire [AW-1:0] prog_addr;
    wire [15:0] prog_data;
    reg         prog_ack = 0;

    dogyuun_rom_loader #(.AW(AW)) u_board_loader (
        .clk(clk), .rst(rst),
        .ioctl_rom(ioctl_rom), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr(ioctl_wr),
        .dwnld_busy(dwnld_busy), .prog_ba(prog_ba), .prog_addr(prog_addr), .prog_data(prog_data),
        .prog_mask(prog_mask), .prog_rd(prog_rd), .prog_we(prog_we), .prog_rdy(1'b0), .prog_ack(prog_ack),
        .cfg_valid(cfg_valid), .cfg_board(), .cfg_two_gp(), .cfg_table(), .cfg_oki_pin7(),
        .cfg_wram_64k(), .cfg_cpu_num(), .cfg_v25_num(), .cfg_oki_inc(), .cfg_oki_wrap(),
        .cfg_dswa(), .cfg_dswb(), .cfg_jmpr(), .cfg_gp0_size(), .cfg_gp1_size(),
        .eeprom_we(), .eeprom_addr(), .eeprom_data(),
        .accepted(), .range_error(range_error), .overflow_error(overflow_error), .last_addr()
    );

    // The controller's programming port: acknowledge each write after 2-12
    // clocks (jtframe_sdram64 takes longer behind a refresh).
    integer wait_n = 0, writes = 0, bad = 0;
    integer seed = 1;
    always @(posedge clk) begin
        prog_ack <= 1'b0;
        if (prog_we && !prog_ack) begin
            if (wait_n == 0) wait_n <= 2 + ($urandom(seed) % 11);
            else if (wait_n == 1) begin
                prog_ack <= 1'b1;
                wait_n   <= 0;
                writes   <= writes + 1;
                // maincpu is bank 0 from the image's region 0, a word = the
                // even byte low.
                if (prog_ba != 2'd0 ||
                    prog_data != {img[32'h1000 + 2 * prog_addr + 1], img[32'h1000 + 2 * prog_addr]}) begin
                    if (bad < 5) $display("BAD write: bank %0d word %h data %h, image %h", prog_ba,
                        prog_addr, prog_data, {img[32'h1000 + 2 * prog_addr + 1], img[32'h1000 + 2 * prog_addr]});
                    bad <= bad + 1;
                end
            end else wait_n <= wait_n - 1;
        end
    end

    // ------------------------------------------------------- video
    reg  [3:0] div = 0;
    reg  [8:0] hc = 0, vc = 0;
    wire       ce = (div == 4'd13);
    reg        hs = 0, vs = 0, hb = 1, vb = 1;
    reg  [7:0] r = 0;
    always @(posedge clk) begin
        div <= ce ? 4'd0 : div + 4'd1;
        if (ce) begin
            hb <= hc >= 320; vb <= vc >= 240;
            hs <= hc >= 340 && hc < 376; vs <= vc >= 244 && vc < 248;
            r  <= hc[7:0] ^ vc[7:0] | 8'h01;
            if (hc == 431) begin hc <= 0; vc <= (vc == 261) ? 0 : vc + 1; end
            else hc <= hc + 1;
        end
    end

    reg clk_vid = 0;
    initial begin #3; forever #74.074 clk_vid = ~clk_vid; end   // 6.75 MHz, a free phase
    wire [23:0] vrgb; wire vde, vhs, vvs;
    pocket_video u_video (
        .clk(clk), .ce_pix(ce), .hs(hs), .vs(vs), .hblank(hb), .vblank(vb),
        .r(r), .g(8'd0), .b(8'd0), .clk_vid(clk_vid),
        .video_rgb(vrgb), .video_de(vde), .video_hs(vhs), .video_vs(vvs), .video_skip()
    );
    integer v_frames = 0, v_lines = 0, v_de = 0, v_since_vs = 99, v_err = 0, v_line_de = 0;
    integer v_de_lines = 0;
    reg vde_q = 0;
    always @(posedge clk_vid) begin
        vde_q <= vde;
        if (!vde && vrgb != 0) begin v_err = v_err + 1; end
        if (vvs) begin
            if (v_frames > 0 && v_de_lines != 240) begin
                $display("video: %0d DE lines in a frame", v_de_lines); v_err = v_err + 1;
            end
            v_frames = v_frames + 1; v_since_vs = 0; v_de_lines = 0;
        end else v_since_vs = v_since_vs + 1;
        if (vhs) begin
            if (v_since_vs < 3) begin $display("video: HS %0d cycles after VS", v_since_vs); v_err = v_err + 1; end
            v_lines = v_lines + 1;
        end
        if (vde) v_line_de = v_line_de + 1;
        if (vde_q && !vde) begin
            if (v_line_de != 320) begin $display("video: %0d DE cycles in a line", v_line_de); v_err = v_err + 1; end
            v_line_de = 0; v_de_lines = v_de_lines + 1;
        end
    end

    // ------------------------------------------------------- the run
    initial begin
        if (!$value$plusargs("rom=%s", path)) path = "build/pocket/batsugun.rom";
        fd = $fopen(path, "rb");
        if (fd == 0) $fatal(1, "cannot open %0s", path);
        for (i = 0; i < LOAD_BYTES; i = i + 1) img[i] = $fgetc(fd);
        $fclose(fd);

        repeat (300) @(posedge clk);
        rst = 0;
        repeat (100) @(posedge clk_74a);
        // APF: one word every ~75 clk_74a cycles, big-endian on the bridge.
        for (i = 0; i < LOAD_BYTES; i = i + 4) begin
            @(posedge clk_74a);
            bridge_addr    <= i;
            bridge_wr_data <= {img[i], img[i+1], img[i+2], img[i+3]};
            bridge_wr      <= 1'b1;
            @(posedge clk_74a);
            bridge_wr      <= 1'b0;
            repeat (73) @(posedge clk_74a);
        end
        repeat (200) @(posedge clk_74a);
        allcomplete = 1;
        fork
            begin wait (rom_loaded); end
            begin repeat (100000) @(posedge clk); $fatal(1, "rom_loaded never rose"); end
        join_any
        disable fork;
        wait (!dwnld_busy);
        // Three more frames of video.
        repeat (3 * 432 * 262 * 14) @(posedge clk);

        $display("loader: %0d bytes taken, %0d SDRAM writes (%0d expected), %0d bad; cfg_valid %0d, range %0d, overflow %0d / %0d, ioctl_rom %0d",
                 bytes, writes, (LOAD_BYTES - 32'h1000) / 2, bad, cfg_valid, range_error,
                 overflow_error, overflow, ioctl_rom);
        $display("video: %0d frames, %0d HS, %0d errors", v_frames, v_lines, v_err);
        if (bytes != LOAD_BYTES || writes != (LOAD_BYTES - 32'h1000) / 2 || bad != 0 || !cfg_valid ||
            range_error || overflow_error || overflow || ioctl_rom || v_err != 0 || v_frames < 4)
            $fatal(1, "FAIL");
        $display("PASS");
        $finish;
    end
endmodule

`default_nettype wire

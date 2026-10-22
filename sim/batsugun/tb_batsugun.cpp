// SPDX-License-Identifier: GPL-3.0-or-later
// Toaplan V2 (Pocket) - board-level harness: the two-GP9001 board and the
// SDRAM controller (tb_batsugun.sv) with jtframe's SDRAM model behind it.
//
//   tb_batsugun <set.rom> <frames> <outdir> [options]
//     --dump 600,3000      write frame_NNNNN.ppm (320 x 240, as the board
//                          scans: unrotated) for these frames
//     --trace FILE         the 68000's bus, tools/mame_toaplan2_bus_trace.lua's
//                          format: "<addr> <R|W> <data> <mask>", "# frame N"
//     --trace-count N      stop the trace after N accesses
//     --trace-data-only    as BUS_TRACE_DATA_ONLY=1: no program ROM reads but
//                          the vectors at 000060-00007f
//     --v25-trace FILE     the V25's external bus: "P <addr> <R|W> <byte>",
//                          its SFR reads "S <offset> R <byte>" (P0 100, P1
//                          108, PT 138, ...), "# reset 0/1", "# frame N"
//     --wav FILE           the board's mono output at its sample rate
//                          (YM2151 rate, 3.375 MHz / 64), 16-bit
//     --stream             stream the whole image through the loader (default:
//                          the header through the loader, the regions written
//                          straight into the SDRAM model, as the loader would)
//     --inputs FILE        "<frame> coin=1 start=1 up=0 b1=1 ..." lines
//     --events FILE        tools/mame_toaplan2_events.lua's events, timed in
//                          clocks from the release of reset: the 68000's
//                          writes to 20001c, the V25's writes to shared 7800
//                          and the 68000's reads of it when they change
//     --save FILE          a checkpoint of the whole run (the board, the
//                          SDRAM, the harness) at every --save-every'th
//                          frame (default 100), written over the last one
//     --restore FILE       go on from a checkpoint to <frames>: stats.csv
//                          is cut back to the checkpoint's frame and
//                          appended to; --trace, --v25-trace, --events and
//                          --wav start afresh at that frame
//
// Frames count from the release of reset, which is where MAME's power-on is:
// the raster and the 68000 start together. Frame N is the picture finished
// at the N-th start of vblank. The board scans frame N out of the copy of
// VRAM, sprites and palette taken at the vblank before it, where MAME draws
// its picture N at frame N's vblank: so frame N here is MAME's picture N-1
// (the dump script's f<N-1>).

#include "Vtb_batsugun.h"
#include "verilated.h"
#include "verilated_save.h"
#include "sdram.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <set>
#include <string>
#include <vector>
#include <sys/stat.h>

static const double CLK_PS = 1e12 / 94.5e6;

struct Wav {
    FILE* f = nullptr;
    uint32_t n = 0;
    void open(const char* path, uint32_t rate) {
        f = fopen(path, "wb");
        if (!f) { perror(path); exit(1); }
        uint8_t h[44] = {0};
        fwrite(h, 1, 44, f);
        this->rate = rate;
    }
    void put(int16_t s) { if (f) { fwrite(&s, 2, 1, f); n++; } }
    void close() {
        if (!f) return;
        auto le32 = [](uint8_t* p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = v >> (8 * i); };
        auto le16 = [](uint8_t* p, uint16_t v) { p[0] = v; p[1] = v >> 8; };
        uint8_t h[44];
        memcpy(h, "RIFF", 4); le32(h + 4, 36 + 2 * n); memcpy(h + 8, "WAVEfmt ", 8);
        le32(h + 16, 16); le16(h + 20, 1); le16(h + 22, 1); le32(h + 24, rate);
        le32(h + 28, rate * 2); le16(h + 32, 2); le16(h + 34, 16);
        memcpy(h + 36, "data", 4); le32(h + 40, 2 * n);
        fseek(f, 0, SEEK_SET); fwrite(h, 1, 44, f); fclose(f); f = nullptr;
    }
    uint32_t rate = 0;
};

static uint32_t le32(const std::vector<uint8_t>& b, size_t o) {
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s set.rom frames outdir [--dump a,b] [--trace f] "
                        "[--trace-count n] [--trace-data-only] [--v25-trace f] [--wav f] "
                        "[--stream] [--inputs f]\n", argv[0]);
        return 2;
    }
    const char* rom_path = argv[1];
    int frames = atoi(argv[2]);
    std::string outdir = argv[3];
    std::set<int> dumps;
    const char *trace_path = nullptr, *v25_path = nullptr, *wav_path = nullptr,
               *inputs_path = nullptr, *events_path = nullptr,
               *save_path = nullptr, *restore_path = nullptr;
    int save_every = 100;
    long trace_count = 0;
    bool data_only = false, stream = false;
    for (int i = 4; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> const char* {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(2); }
            return argv[++i];
        };
        if (a == "--dump") {
            std::string s = next();
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(',', p);
                if (q == std::string::npos) q = s.size();
                if (q > p) dumps.insert(atoi(s.substr(p, q - p).c_str()));
                p = q + 1;
            }
        }
        else if (a == "--trace") trace_path = next();
        else if (a == "--trace-count") trace_count = atol(next());
        else if (a == "--trace-data-only") data_only = true;
        else if (a == "--v25-trace") v25_path = next();
        else if (a == "--wav") wav_path = next();
        else if (a == "--stream") stream = true;
        else if (a == "--inputs") inputs_path = next();
        else if (a == "--events") events_path = next();
        else if (a == "--save") save_path = next();
        else if (a == "--save-every") save_every = atoi(next());
        else if (a == "--restore") restore_path = next();
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
    }
    mkdir(outdir.c_str(), 0755);

    std::vector<uint8_t> rom;
    {
        FILE* f = fopen(rom_path, "rb");
        if (!f) { perror(rom_path); return 1; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        rom.resize(n);
        if (fread(rom.data(), 1, n, f) != (size_t)n) { perror("read"); return 1; }
        fclose(f);
    }
    if (rom.size() < 0x1000 || memcmp(rom.data(), "TPV2", 4)) {
        fprintf(stderr, "%s: not a Toaplan V2 image\n", rom_path);
        return 1;
    }

    Verilated::commandArgs(argc, argv);
    Vtb_batsugun* t = new Vtb_batsugun;
    SDRAMModel sdram(9);
    uint64_t cyc = 0;

    t->clk = 0; t->rst = 1; t->cold_rst = 1;
    t->ioctl_rom = 0; t->ioctl_wr = 0; t->ioctl_addr = 0; t->ioctl_dout = 0;
    t->joy1_n = 0x7f; t->joy2_n = 0x7f; t->start_n = 0xf; t->coin_n = 0xf;
    t->service_n = 1; t->test_n = 1; t->pause_n = 1; t->dipsw = 0;
    t->sdram_dq = 0;

    // One clock: the board's edge, then the SDRAM model on the falling edge
    // (its clock is the board's), its data on the pins for the next edge.
    auto tick = [&]() {
        t->clk = 1; t->eval();
        SDRAMPins p;
        p.cke = t->sdram_cke; p.ncs = t->sdram_ncs; p.nras = t->sdram_nras;
        p.ncas = t->sdram_ncas; p.nwe = t->sdram_nwe; p.ba = t->sdram_ba;
        p.dqm = t->sdram_dqm; p.a = t->sdram_a; p.din = t->sdram_din;
        SDRAMOutputs o = sdram.tick(p, (uint64_t)(cyc * CLK_PS + CLK_PS / 2));
        t->clk = 0;
        t->sdram_dq = o.dq_drive ? o.dq : 0;
        t->eval();
        cyc++;
    };

    uint64_t cyc0 = 0;
    if (!restore_path) {
    for (int i = 0; i < 32; i++) tick();
    t->cold_rst = 0;
    // The SDRAM's power-up sequence
    for (int i = 0; i < 200000 && t->sdram_init; i++) tick();
    if (t->sdram_init) { fprintf(stderr, "SDRAM init did not finish\n"); return 1; }

    // ------------------------------------------------------------ the image
    auto send = [&](uint32_t a, uint8_t d) {
        // One byte; the loader takes three clocks to place it, then may
        // write a word, held until the SDRAM controller takes it.
        while (t->ld_prog_we) tick();
        t->ioctl_addr = a; t->ioctl_dout = d; t->ioctl_wr = 1; tick();
        t->ioctl_wr = 0;
        for (int k = 0; k < 4; k++) tick();
    };
    uint32_t img_len = le32(rom, 0x1c);
    if (img_len > rom.size()) img_len = rom.size();
    t->ioctl_rom = 1;
    uint32_t end = stream ? img_len : 0x1000;
    for (uint32_t a = 0; a < end; a++) {
        send(a, rom[a]);
        if (stream && (a & 0xfffff) == 0)
            fprintf(stderr, "loading %u of %u KB\n", a >> 10, img_len >> 10);
    }
    t->ioctl_rom = 0;
    for (int i = 0; i < 100000 && t->dwnld_busy; i++) tick();
    for (int i = 0; i < 64; i++) tick();
    // As the loader maps them: maincpu bank 0, gp9001_0 bank 1, gp9001_1
    // bank 2, oki bank 3, audiocpu bank 3 at 0x40000 bytes. Streamed, the
    // SDRAM is checked against this map instead.
    {
        static const int bank_of[6] = {0, 3, 1, 2, 3, -1};
        static const uint32_t base_of[6] = {0, 0x40000, 0, 0, 0, 0};
        uint64_t words = 0, bad = 0;
        for (int r = 0; r < 6; r++) {
            uint32_t off = le32(rom, 0x20 + 8 * r), len = le32(rom, 0x24 + 8 * r);
            if (!len || bank_of[r] < 0) continue;
            for (uint32_t k = 0; k + 1 < len; k += 2) {
                uint16_t w = rom[off + k] | (rom[off + k + 1] << 8);
                if (!stream) sdram.write_word(bank_of[r], (base_of[r] + k) >> 1, w, 0);
                else {
                    words++;
                    if (sdram.read_word(bank_of[r], (base_of[r] + k) >> 1) != w && bad++ < 4)
                        fprintf(stderr, "SDRAM bank %d word %x: %04x, image %04x\n", bank_of[r],
                                (base_of[r] + k) >> 1, sdram.read_word(bank_of[r], (base_of[r] + k) >> 1), w);
                }
            }
        }
        if (stream) {
            fprintf(stderr, "streamed: %llu of %llu SDRAM words as the image maps them\n",
                    (unsigned long long)(words - bad), (unsigned long long)words);
            if (bad) return 1;
        }
    }
    if (!t->ld_cfg_valid || t->ld_range_error || t->ld_overflow_error) {
        fprintf(stderr, "loader: cfg_valid %d range_error %d overflow_error %d\n",
                t->ld_cfg_valid, t->ld_range_error, t->ld_overflow_error);
        return 1;
    }
    fprintf(stderr, "image loaded (%s) at clock %llu\n", stream ? "streamed" : "header streamed, regions preloaded",
            (unsigned long long)cyc);
    t->rst = 0;
    cyc0 = cyc;
    }

    // ------------------------------------------------------------- inputs
    struct Step { int frame; std::string name; int val; };
    std::vector<Step> plan;
    size_t plan_i = 0;
    if (inputs_path) {
        FILE* f = fopen(inputs_path, "r");
        if (!f) { perror(inputs_path); return 1; }
        char line[512];
        while (fgets(line, sizeof line, f)) {
            char* save = nullptr;
            char* tok = strtok_r(line, " \t\r\n", &save);
            if (!tok || tok[0] == '#') continue;
            int fr = atoi(tok);
            while ((tok = strtok_r(nullptr, " \t\r\n", &save))) {
                char* eq = strchr(tok, '=');
                if (!eq) continue;
                *eq = 0;
                plan.push_back({fr, tok, atoi(eq + 1)});
            }
        }
        fclose(f);
    }
    auto apply_inputs = [&](int fr) {
        while (plan_i < plan.size() && plan[plan_i].frame <= fr) {
            const Step& s = plan[plan_i++];
            // joystick = {B3,B2,B1,U,D,L,R}, active low (dogyuun_inputs)
            static const char* names[] = {"right", "left", "down", "up", "b1", "b2", "b3"};
            for (int b = 0; b < 7; b++)
                if (s.name == names[b]) {
                    if (s.val) t->joy1_n &= ~(1u << b); else t->joy1_n |= 1u << b;
                }
            if (s.name == "coin")  { if (s.val) t->coin_n &= ~1u; else t->coin_n |= 1u; }
            if (s.name == "start") { if (s.val) t->start_n &= ~1u; else t->start_n |= 1u; }
            if (s.name == "service") t->service_n = !s.val;
            if (s.name == "test")    t->test_n = !s.val;
            if (s.name == "pause")   t->pause_n = !s.val;
        }
    };

    // ------------------------------------------------------------- outputs
    FILE* trace = trace_path ? fopen(trace_path, "w") : nullptr;
    FILE* v25 = v25_path ? fopen(v25_path, "w") : nullptr;
    FILE* events = events_path ? fopen(events_path, "w") : nullptr;
    int ev_last_7800 = -1;
    Wav wav;
    if (wav_path) wav.open(wav_path, 52734);   // 3.375 MHz / 64
    long traced = 0;
    std::vector<uint8_t> img(320 * 240 * 3, 0);
    int x = 0, y = 0, frame = 0;
    bool prev_hb = true, prev_vb = true, as_prev = true;
    bool v25_act_prev = false, v25_rst_prev = false, sample_prev = false, v25_rd = false;
    uint32_t v25_a = 0; uint8_t v25_d = 0;
    uint32_t cyc_addr = 0, cyc_mask = 0; bool cyc_rd = true, cyc_iack = false;
    uint16_t cyc_dout = 0;
    uint64_t v25_writes = 0, m68_cycles = 0, miss = 0;
    unsigned missing_max = 0;
    uint64_t vs_ready = 0, vs_color = 0, vs_pal = 0;
    uint64_t dbg_rd[4] = {0}, dbg_ack[4] = {0}, dbg_rdy[4] = {0}, dbg_busy[4] = {0}, dbg_valid[4] = {0};

    // Checkpoints: the model as Verilator saves it, then the harness's
    // own state and the SDRAM model's.
#define LOOP_STATE(X) X(cyc) X(cyc0) X(frame) X(x) X(y) X(prev_hb) X(prev_vb) X(as_prev) \
    X(v25_act_prev) X(v25_rst_prev) X(sample_prev) X(v25_rd) X(v25_a) X(v25_d) X(cyc_addr) \
    X(cyc_mask) X(cyc_rd) X(cyc_iack) X(cyc_dout) X(v25_writes) X(m68_cycles) X(miss) \
    X(missing_max) X(vs_ready) X(vs_color) X(vs_pal) X(plan_i) X(ev_last_7800) X(traced)
    static const uint32_t CKPT_MAGIC = 0x54504b31;   // "TPK1"
    auto save = [&]() {
        std::string tmp = std::string(save_path) + ".tmp";
        {
            VerilatedSave os;
            os.open(tmp.c_str());
            if (!os.isOpen()) { perror(tmp.c_str()); exit(1); }
            os << *t;
            os.write(&CKPT_MAGIC, sizeof CKPT_MAGIC);
#define PUT(v) os.write(&v, sizeof v);
            LOOP_STATE(PUT)
#undef PUT
            os.write(img.data(), img.size());
            sdram.save([&](const void* p, size_t n) { os.write(p, n); });
            os.close();
        }
        if (rename(tmp.c_str(), save_path)) { perror(save_path); exit(1); }
    };
    std::string stats_path = outdir + "/stats.csv";
    FILE* stats;
    if (restore_path) {
        VerilatedRestore os;
        os.open(restore_path);
        if (!os.isOpen()) { perror(restore_path); return 1; }
        os >> *t;
        uint32_t magic = 0;
        os.read(&magic, sizeof magic);
        if (magic != CKPT_MAGIC) { fprintf(stderr, "%s: not a checkpoint\n", restore_path); return 1; }
#define GET(v) os.read(&v, sizeof v);
        LOOP_STATE(GET)
#undef GET
        os.read(img.data(), img.size());
        sdram.load([&](void* p, size_t n) { os.read(p, n); });
        os.close();
        // stats.csv as it stood at the checkpoint
        std::vector<std::string> keep;
        if (FILE* f = fopen(stats_path.c_str(), "r")) {
            char line[512];
            while (fgets(line, sizeof line, f))
                if (keep.empty() || atoi(line) <= frame) keep.push_back(line);
            fclose(f);
        }
        stats = fopen(stats_path.c_str(), "w");
        for (auto& l : keep) fputs(l.c_str(), stats);
        fprintf(stderr, "restored at frame %d, clock %llu\n", frame, (unsigned long long)cyc);
    } else {
        stats = fopen(stats_path.c_str(), "w");
        fprintf(stats, "frame,clocks,m68_cycles,v25_writes,v25_pc,deadline_miss,m68_wait_backlog_max,px_line_ready,px_color_nz,px_palette_nz\n");
        apply_inputs(0);
    }
    while (frame < frames) {
        tick();

        // 68000: one line per bus cycle, when AS goes up (the data latched).
        bool as = !t->m68_as_n;
        if (as && !as_prev) { cyc_iack = t->m68_iack; }
        if (as) {
            cyc_addr = t->m68_addr; cyc_rd = t->m68_rw;
            cyc_mask = (!t->m68_uds_n ? 0xff00 : 0) | (!t->m68_lds_n ? 0x00ff : 0);
            if (!cyc_rd) cyc_dout = t->m68_dout;
        }
        if (!as && as_prev) {
            m68_cycles++;
            if (events && !cyc_rd && cyc_addr == 0x20001c)
                fprintf(events, "%llu m68 W 20001c %04x\n", (unsigned long long)(cyc - cyc0),
                        cyc_dout & cyc_mask);
            if (events && cyc_rd && cyc_addr == 0x21f000 && (int)(t->m68_din & 0xff) != ev_last_7800) {
                ev_last_7800 = t->m68_din & 0xff;
                fprintf(events, "%llu m68 R 21f000 %02x\n", (unsigned long long)(cyc - cyc0), ev_last_7800);
            }
            bool vec = cyc_addr >= 0x60 && cyc_addr < 0x80;
            if (trace && !cyc_iack && cyc_mask &&
                !(data_only && cyc_rd && cyc_addr < 0x80000 && !vec)) {
                fprintf(trace, "%06x %c %04x %04x\n", cyc_addr, cyc_rd ? 'R' : 'W',
                        cyc_rd ? t->m68_din : cyc_dout, cyc_mask);
                if (trace_count && ++traced >= trace_count) { fclose(trace); trace = nullptr; }
            }
        }
        as_prev = as;

        // V25: one line per external bus access, at its strobe.
        bool rn = t->v25_reset_n;
        if (rn != v25_rst_prev && v25) fprintf(v25, "# reset %d\n", rn ? 1 : 0);
        v25_rst_prev = rn;
        if (v25 && t->v25_sfr_read)
            fprintf(v25, "S %05x R %02x\n", t->v25_sfr_index, t->v25_sfr_data);
        bool act = t->v25_mem_active;
        if (act && !v25_act_prev) {
            if (!t->v25_r_w) v25_writes++;
            if (events && !t->v25_r_w && (t->v25_addr & 0x80000) && (t->v25_addr & 0x7fff) == 0x7800)
                fprintf(events, "%llu v25 W 07800 %02x\n", (unsigned long long)(cyc - cyc0), t->v25_dout);
            if (v25 && !t->v25_r_w)
                fprintf(v25, "P %05x W %02x\n", t->v25_addr, t->v25_dout);
        }
        if (!act && v25_act_prev && v25 && v25_rd)
            fprintf(v25, "P %05x R %02x\n", v25_a, v25_d);
        if (act) { v25_a = t->v25_addr; v25_d = t->v25_din; v25_rd = t->v25_r_w; }
        v25_act_prev = act;

        if (t->sample && !sample_prev) wav.put((int16_t)t->snd);
        sample_prev = t->sample;
        miss |= t->video_miss;
        for (int b = 0; b < 4; b++) {
            dbg_rd[b] += (t->dbg_ba_rd >> b) & 1; dbg_ack[b] += (t->dbg_ba_ack >> b) & 1;
            dbg_rdy[b] += (t->dbg_ba_rdy >> b) & 1; dbg_busy[b] += (t->dbg_engine_busy >> b) & 1;
            dbg_valid[b] += (t->dbg_line_valid >> b) & 1;
        }
        if (t->m68_missing > missing_max) missing_max = t->m68_missing;

        // Video
        if (t->pxl_cen) {
            bool hb = !t->LHBL, vb = !t->LVBL;
            if (!vb && prev_vb) { x = 0; y = 0; }   // the first line starts
            if (!hb && !vb) {
                vs_ready += t->vid_line_ready; vs_color += t->vid_color != 0;
                vs_pal += t->vid_palette != 0;
                if (x < 320 && y < 240) {
                    uint8_t* px = &img[(y * 320 + x) * 3];
                    px[0] = t->red; px[1] = t->green; px[2] = t->blue;
                }
                x++;
            }
            if (hb && !prev_hb && !vb) { y++; x = 0; }
            if (vb && !prev_vb) {
                frame++;
                if (events) fprintf(events, "%llu vblank %d\n", (unsigned long long)(cyc - cyc0), frame);
                if (trace) fprintf(trace, "# frame %d\n", frame);
                if (v25) fprintf(v25, "# frame %d\n", frame);
                if (dumps.count(frame)) {
                    char fn[512];
                    snprintf(fn, sizeof fn, "%s/frame_%05d.ppm", outdir.c_str(), frame);
                    FILE* f = fopen(fn, "wb");
                    fprintf(f, "P6\n320 240\n255\n");
                    fwrite(img.data(), 1, img.size(), f);
                    fclose(f);
                }
                fprintf(stats, "%d,%llu,%llu,%llu,%05x,%llx,%u,%llu,%llu,%llu\n", frame,
                        (unsigned long long)(cyc - cyc0), (unsigned long long)m68_cycles,
                        (unsigned long long)v25_writes, t->v25_pc, (unsigned long long)miss,
                        missing_max, (unsigned long long)vs_ready,
                        (unsigned long long)vs_color, (unsigned long long)vs_pal);
                missing_max = 0; vs_ready = vs_color = vs_pal = 0;
                fflush(stats);
                if (getenv("TB_DEBUG")) {
                    fprintf(stderr, "frame %d:", frame);
                    for (int b = 0; b < 4; b++)
                        fprintf(stderr, " b%d rd %llu ack %llu rdy %llu busy %llu valid %llu |", b,
                                (unsigned long long)dbg_rd[b], (unsigned long long)dbg_ack[b],
                                (unsigned long long)dbg_rdy[b], (unsigned long long)dbg_busy[b],
                                (unsigned long long)dbg_valid[b]);
                    fprintf(stderr, "\n");
                    for (int b = 0; b < 4; b++) dbg_rd[b] = dbg_ack[b] = dbg_rdy[b] = dbg_busy[b] = dbg_valid[b] = 0;
                }
                if (frame % 10 == 0)
                    fprintf(stderr, "frame %d of %d\n", frame, frames);
                apply_inputs(frame);
                x = 0; y = 0;
                if (save_path && save_every > 0 && frame % save_every == 0) {
                    prev_hb = hb; prev_vb = vb;
                    save();
                }
            }
            prev_hb = hb; prev_vb = vb;
        }
    }
    if (trace) fclose(trace);
    if (v25) fclose(v25);
    if (events) fclose(events);
    wav.close();
    fclose(stats);
    t->final();
    delete t;
    return 0;
}

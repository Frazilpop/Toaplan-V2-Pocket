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
//                          the header and the audiocpu region through the
//                          loader, the other regions written straight into
//                          the SDRAM model, as the loader would)
//     --inputs FILE        "<frame> coin=1 start=1 up=0 b1=1 ..." lines
//                          (player 1; p2_/p3_ before a name for players 2
//                          and 3: p2_coin, p3_start, p3_b1 ...)
//     --nv-in FILE         FixEight: 128 bytes written into the 93C46 after
//                          the image (as APF writes a .sav: MAME's nvram
//                          file order, each word low byte first)
//     --nv-out FILE        FixEight: the 93C46's 128 bytes at the end, in
//                          the same order
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
// Built with -DANALOGIZER (sim/batsugun/build.sh --anz, build/obj_anz/), the
// shell's pocket_analogizer is on the board's raster, on a 27 MHz clk_anz
// that rises with clk every seventh half-period of clk (both from the PLL's
// 756 MHz VCO, /8 and /28):
//     --anz-file FILE      analogizer.bin: its first four bytes written to
//                          0xF7000000 as APF's bridge does, the first byte in
//                          [31:24], at the start (after a --restore too)
//     --anz-raw N          anz_NNNNN.raw: the cartridge pins at every
//                          clk_anz edge from the start of vblank N-1 to that
//                          of N+1, so picture N and the scandoubler's lines
//                          after it, five bytes an edge – bank3, bank2,
//                          bank1, {pin31_dir, pwroff, pin30_dir, pin30,
//                          bank3_dir, bank2_dir, bank1_dir, bank0_dir} and
//                          {pin31 in, 3'b0, bank0[7:4]} – for
//                          tools/pocket/check_analogizer.py
//     --anz-pad snes|nes|db15  two pads of that kind on the SNAC port,
//                          answering its latch and clock as the pads' shift
//                          registers do; from 20 frames in, each button
//                          pressed in turn for four frames (pad 2 the next
//                          button in the list). anz_keys.csv has, at the end
//                          of every frame, the buttons held and the players'
//                          controls (key1-key3) as pocket_analogizer gives
//                          them
//     --anz-cont A,B,C     the Pocket's own controls (cont1-3_key[15:0], hex)
// At the end it prints the word pocket_analogizer took and the clk_anz edges
// on which the pins, the Analogizer off, differed from the template's
// tie-offs.
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
#include <functional>
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
               *save_path = nullptr, *restore_path = nullptr,
               *nv_in_path = nullptr, *nv_out_path = nullptr;
    int save_every = 100;
    long trace_count = 0;
    bool data_only = false, stream = false;
#ifdef ANALOGIZER
    const char* anz_file = nullptr;
    int anz_raw = -1;
    std::string anz_pad;
    unsigned anz_cont[3] = {0, 0, 0};
#endif
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
        else if (a == "--nv-in") nv_in_path = next();
        else if (a == "--nv-out") nv_out_path = next();
#ifdef ANALOGIZER
        else if (a == "--anz-file") anz_file = next();
        else if (a == "--anz-raw") anz_raw = atoi(next());
        else if (a == "--anz-pad") anz_pad = next();
        else if (a == "--anz-cont") sscanf(next(), "%x,%x,%x", &anz_cont[0], &anz_cont[1], &anz_cont[2]);
#endif
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
    t->joy1_n = 0x7f; t->joy2_n = 0x7f; t->joy3_n = 0x7f;
    t->nv_addr = 0; t->nv_din = 0; t->nv_we = 0; t->start_n = 0xf; t->coin_n = 0xf;
    t->service_n = 1; t->test_n = 1; t->pause_n = 1; t->dipsw = 0;
    t->sdram_dq = 0;
#ifdef ANALOGIZER
    t->clk_anz = 0; t->anz_wr = 0; t->anz_data = 0;
    t->anz_cont1 = anz_cont[0]; t->anz_cont2 = anz_cont[1]; t->anz_cont3 = anz_cont[2];
    t->anz_bank0_in = 0xf; t->anz_pin31_in = 1;
#endif

    // One clock: the board's edge, then the SDRAM model on the falling edge
    // (its clock is the board's), its data on the pins for the next edge.
    // clk_anz (ANALOGIZER) rises on every seventh half-period of clk, with a
    // rising edge of clk and a falling one in turn, and falls four
    // half-periods later; anz_edge sees the pins after each rise.
    std::function<void()> anz_edge;
#ifdef ANALOGIZER
    auto anz_clk = [&](uint64_t half) {
        unsigned ph = half % 7;
        if (ph == 0) t->clk_anz = 1;
        else if (ph == 4) t->clk_anz = 0;
        return ph == 0;
    };
#else
    auto anz_clk = [&](uint64_t) { return false; };
#endif
    auto tick = [&]() {
        t->clk = 1;
        bool rose = anz_clk(2 * cyc);
        t->eval();
        if (rose && anz_edge) anz_edge();
        SDRAMPins p;
        p.cke = t->sdram_cke; p.ncs = t->sdram_ncs; p.nras = t->sdram_nras;
        p.ncas = t->sdram_ncas; p.nwe = t->sdram_nwe; p.ba = t->sdram_ba;
        p.dqm = t->sdram_dqm; p.a = t->sdram_a; p.din = t->sdram_din;
        SDRAMOutputs o = sdram.tick(p, (uint64_t)(cyc * CLK_PS + CLK_PS / 2));
        t->clk = 0;
        t->sdram_dq = o.dq_drive ? o.dq : 0;
        rose = anz_clk(2 * cyc + 1);
        t->eval();
        if (rose && anz_edge) anz_edge();
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
    // TP-023's V25 ROM goes into block RAM through the loader's audio port,
    // and TP-026's EEPROM into the 93C46, so the audiocpu and eeprom regions
    // are always streamed (32 KB, 128 bytes).
    if (!stream) {
        for (int r : {1, 5}) {
            uint32_t off = le32(rom, 0x20 + 8 * r), len = le32(rom, 0x24 + 8 * r);
            for (uint32_t k = 0; k < len; k++) send(off + k, rom[off + k]);
        }
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
    if (nv_in_path) {
        // As pocket_nvram writes a save: word w = file bytes {2w + 1, 2w}.
        FILE* f = fopen(nv_in_path, "rb");
        if (!f) { perror(nv_in_path); return 1; }
        uint8_t b[128];
        if (fread(b, 1, 128, f) != 128) { fprintf(stderr, "%s: not 128 bytes\n", nv_in_path); return 1; }
        fclose(f);
        for (int w = 0; w < 64; w++) {
            t->nv_addr = w; t->nv_din = b[2 * w] | (b[2 * w + 1] << 8); t->nv_we = 1; tick();
        }
        t->nv_we = 0; tick();
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
            int pl = 0;
            std::string n = s.name;
            if (n.size() > 3 && n[0] == 'p' && (n[1] == '2' || n[1] == '3') && n[2] == '_') {
                pl = n[1] - '1'; n = n.substr(3);
            }
            auto set = [&](auto& port, unsigned bit) {
                if (s.val) port &= ~(1u << bit); else port |= 1u << bit;
            };
            for (int b = 0; b < 7; b++)
                if (n == names[b]) {
                    if (pl == 0) set(t->joy1_n, b);
                    else if (pl == 1) set(t->joy2_n, b);
                    else set(t->joy3_n, b);
                }
            if (n == "coin")  set(t->coin_n, pl);
            if (n == "start") set(t->start_n, pl);
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
    // Per frame: line deadlines missed (pulses, all four engines) and each
    // engine's longest line build in clocks (a line is 432 x 14 = 6048).
    unsigned miss_lines = 0, build_max[4] = {0};
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
        fprintf(stats, "frame,clocks,m68_cycles,v25_writes,v25_pc,deadline_miss,m68_wait_backlog_max,px_line_ready,px_color_nz,px_palette_nz,miss_lines,build_gp0_tile,build_gp0_obj,build_gp1_tile,build_gp1_obj\n");
        apply_inputs(0);
    }
#ifdef ANALOGIZER
    // the inputs again, since a --restore brings back the checkpoint's;
    // analogizer.bin, as the bridge writes it, for a few clocks
    t->anz_cont1 = anz_cont[0]; t->anz_cont2 = anz_cont[1]; t->anz_cont3 = anz_cont[2];
    t->anz_bank0_in = 0xf; t->anz_pin31_in = 1;
    int anz_wr_left = 0;
    if (anz_file) {
        uint8_t b[4] = {0, 0, 0, 0};
        FILE* f = fopen(anz_file, "rb");
        if (!f) { perror(anz_file); return 1; }
        size_t n = fread(b, 1, 4, f);
        fclose(f);
        t->anz_data = (uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
        t->anz_wr = 1;
        anz_wr_left = 8;
        fprintf(stderr, "analogizer.bin: %zu bytes, word %08x\n", n,
                (unsigned)(b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24));
    }
    std::vector<uint8_t> anz_buf, anz_prev;
    uint64_t anz_off_edges = 0, anz_idle_bad = 0;
    int anz_idx = 0, anz_frame0 = frame;
    bool anz_clk_prev = false;
    uint32_t anz_held[2] = {0, 0}, anz_held_db15 = 0;
    // each pad's buttons, in the order its shift register sends them
    static const char* snes_b[] = {"B", "Y", "Select", "Start", "Up", "Down", "Left", "Right", "A", "X", "L", "R"};
    static const char* nes_b[]  = {"A", "B", "Select", "Start", "Up", "Down", "Left", "Right"};
    // DB15's two 74HC165s: P1 D C B A Right Left Down Up, P2 Right Left Down
    // Up, P1 F E Select Start, P2 F E Select Start D C B A
    static const int db15_p1[] = {0, 1, 2, 3, 4, 5, 6, 7, 13, 12, 14, 15};
    static const int db15_p2[] = {20, 21, 22, 23, 8, 9, 10, 11, 17, 16, 18, 19};
    static const char* db15_n[] = {"D", "C", "B", "A", "Right", "Left", "Down", "Up", "E", "F", "Select", "Start"};
    const char** pad_names = anz_pad == "snes" ? snes_b : anz_pad == "nes" ? nes_b : db15_n;
    int pad_n = anz_pad == "nes" ? 8 : 12;
    FILE* anz_keys = anz_pad.empty() ? nullptr : fopen((outdir + "/anz_keys.csv").c_str(), "w");
    if (anz_keys) fprintf(anz_keys, "frame,pad1,pad2,key1,key2,key3,p1_snac\n");
    // the buttons held in frame f (counted from the start of this run), pad_n none
    auto anz_press = [&](int f, int& k, int& k2) {
        k = f >= 20 ? ((f - 20) / 4) % (pad_n + 1) : pad_n;
        k2 = k < pad_n ? (k + 1) % pad_n : pad_n;
    };
    auto anz_hold = [&](int f) {
        int n, n2;
        anz_press(f, n, n2);
        if (anz_pad == "db15")
            anz_held_db15 = (n < pad_n ? 1u << db15_p1[n] : 0) | (n2 < pad_n ? 1u << db15_p2[n2] : 0);
        else {
            anz_held[0] = n < pad_n ? 1u << n : 0;
            anz_held[1] = n2 < pad_n ? 1u << n2 : 0;
        }
    };
    anz_hold(0);
    anz_edge = [&]() {
        uint8_t b3 = t->anz_bank3, b2 = t->anz_bank2, b1 = t->anz_bank1;
        uint8_t misc = (t->anz_bank0_dir & 1) | (t->anz_bank1_dir & 1) << 1 | (t->anz_bank2_dir & 1) << 2 |
                       (t->anz_bank3_dir & 1) << 3 | (t->anz_pin30 & 1) << 4 | (t->anz_pin30_dir & 1) << 5 |
                       (t->anz_pwroff & 1) << 6 | (t->anz_pin31_dir & 1) << 7;
        if (anz_raw >= 0) {
            anz_buf.push_back(b3); anz_buf.push_back(b2); anz_buf.push_back(b1); anz_buf.push_back(misc);
            anz_buf.push_back((uint8_t)((t->anz_pin31_in & 1) << 7 | (t->anz_bank0 & 0xf)));
        }
        if (!(t->anz_cfg & 0x20)) {
            anz_off_edges++;
            // the template's: banks 1-3 inputs, bank0 an output at F, pin30
            // driven low, pwroff low, pin31 an input
            if ((misc & 0xdf) != 0x01 || t->anz_bank0 != 0xf) anz_idle_bad++;
        }
        // the pads: shift registers on the latch (bank1[7]) and clock (bank1[6])
        if (anz_pad.empty()) return;
        bool lat = b1 >> 7 & 1, clk = b1 >> 6 & 1;
        bool db15 = anz_pad == "db15";
        bool load = db15 ? !lat : lat;          // DB15's 74HC165s load on a low latch
        if (load) anz_idx = 0;
        else if (clk && !anz_clk_prev) anz_idx++;
        anz_clk_prev = clk;
        auto bit = [&](int pad, int i) -> int {   // 0 pressed, 1 released
            if (db15) return (i < 24 && (anz_held_db15 >> i & 1)) ? 0 : 1;
            if (i >= 16) return 0;                // low after the sixteenth, as a pad is
            return (i < 12 && (anz_held[pad] >> i & 1)) ? 0 : 1;
        };
        int d1 = bit(0, anz_idx), d2 = db15 ? 1 : bit(1, anz_idx);
        t->anz_bank0_in = 0xc | d2 << 1 | d1;  // IO3 = bank0[4], IN7 = bank0[5]
        t->anz_pin31_in = db15 ? d1 : 1;       // DB15's data twice (crossed cables)
    };
#endif
    while (frame < frames) {
        tick();
#ifdef ANALOGIZER
        if (anz_wr_left && --anz_wr_left == 0) t->anz_wr = 0;
#endif

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
        if (t->video_miss) miss_lines++;
        for (int b = 0; b < 4; b++) {
            unsigned c = (unsigned)(t->dbg_build_cycles >> (16 * b)) & 0xffff;
            if (c > build_max[b]) build_max[b] = c;
        }
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
                fprintf(stats, "%d,%llu,%llu,%llu,%05x,%llx,%u,%llu,%llu,%llu,%u,%u,%u,%u,%u\n", frame,
                        (unsigned long long)(cyc - cyc0), (unsigned long long)m68_cycles,
                        (unsigned long long)v25_writes, t->v25_pc, (unsigned long long)miss,
                        missing_max, (unsigned long long)vs_ready,
                        (unsigned long long)vs_color, (unsigned long long)vs_pal,
                        miss_lines, build_max[0], build_max[1], build_max[2], build_max[3]);
                missing_max = 0; vs_ready = vs_color = vs_pal = 0;
                miss_lines = 0;
                for (int b = 0; b < 4; b++) build_max[b] = 0;
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
#ifdef ANALOGIZER
                if (anz_raw >= 0 && frame == anz_raw + 1) {
                    char fn[512];
                    snprintf(fn, sizeof fn, "%s/anz_%05d.raw", outdir.c_str(), anz_raw);
                    FILE* f = fopen(fn, "wb");
                    fwrite(anz_prev.data(), 1, anz_prev.size(), f);
                    fwrite(anz_buf.data(), 1, anz_buf.size(), f);
                    fclose(f);
                }
                anz_prev.swap(anz_buf);
                anz_buf.clear();
                if (anz_keys) {
                    // what was held this frame, and the controls it gave
                    int k, k2;
                    anz_press(frame - 1 - anz_frame0, k, k2);
                    fprintf(anz_keys, "%d,%s,%s,%04x,%04x,%04x,%d\n", frame, k < pad_n ? pad_names[k] : "-",
                            k2 < pad_n ? pad_names[k2] : "-", (unsigned)t->anz_key1, (unsigned)t->anz_key2,
                            (unsigned)t->anz_key3, (int)t->anz_p1_snac);
                    anz_hold(frame - anz_frame0);
                }
#endif
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
    if (nv_out_path) {
        FILE* f = fopen(nv_out_path, "wb");
        if (!f) { perror(nv_out_path); return 1; }
        for (int w = 0; w < 64; w++) {
            t->nv_addr = w; tick(); tick();
            uint16_t v = t->nv_dout;
            uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
            fwrite(b, 1, 2, f);
        }
        fclose(f);
    }
#ifdef ANALOGIZER
    if (anz_keys) fclose(anz_keys);
    fprintf(stderr, "analogizer: word taken %08x; pins off the template's on %llu of %llu edges with it off; "
            "Pocket screen %s\n", (unsigned)t->anz_cfg, (unsigned long long)anz_idle_bad,
            (unsigned long long)anz_off_edges, t->anz_pocket_off ? "off" : "on");
#endif
    if (trace) fclose(trace);
    if (v25) fclose(v25);
    if (events) fclose(events);
    wav.close();
    fclose(stats);
    t->final();
    delete t;
    return 0;
}

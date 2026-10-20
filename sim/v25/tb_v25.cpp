// Drive tb_v25 from a MAME feed (tools/mame_toaplan2_v25_feed.lua) and stop
// at the first clock where the V25 wrapper and upstream's disagree.
//
//   Vtb_v25 <feed.txt> [clocks] [cen_num] [secure]
//   cen_num 25 (Dogyuun), 32 (Batsugun); secure 1 nitro (Dogyuun), 0 plain (Batsugun)
#include "Vtb_v25.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

struct Event { uint64_t clock; char kind; unsigned addr, data; };

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <feed.txt> [clocks]\n", argv[0]);
        return 2;
    }
    uint64_t limit = argc > 2 ? std::strtoull(argv[2], nullptr, 0) : 600000000ull;
    unsigned cen_num = argc > 3 ? std::strtoul(argv[3], nullptr, 0) : 25;
    unsigned secure = argc > 4 ? std::strtoul(argv[4], nullptr, 0) : 1;
    std::vector<Event> feed;
    FILE *f = std::fopen(argv[1], "r");
    if (!f) { std::perror(argv[1]); return 2; }
    char kind; unsigned long long clock; unsigned a, d;
    char line[128];
    while (std::fgets(line, sizeof line, f)) {
        if (std::sscanf(line, "W %llu %x %x", &clock, &a, &d) == 3)
            feed.push_back({clock, 'W', a, d});
        else if (std::sscanf(line, "R %llu %u", &clock, &a) == 2)
            feed.push_back({clock, 'R', 0, a});
    }
    std::fclose(f);

    Verilated::commandArgs(argc, argv);
    Vtb_v25 tb;
    size_t next = 0;
    uint64_t writes = 0, ym_writes = 0;
    int reset_line = 0;
    bool was_write = false;
    unsigned hist[16] = {0}, hist_n = 0, last_pc = ~0u;
    tb.clk = 0;
    tb.reset_n = 0;
    tb.cen_num = cen_num;
    tb.secure_mode = secure ? 1 : 0;
    tb.eval();
    for (uint64_t t = 0; t < limit; t++) {
        tb.host_we = 0;
        // The upload's writes come faster than one a clock only in MAME's
        // timing; one a clock is applied, the rest follow.
        while (next < feed.size() && feed[next].clock <= t) {
            const Event &e = feed[next];
            if (e.kind == 'R') {
                reset_line = e.data;
                next++;
                continue;
            }
            tb.host_we = 1;
            tb.host_addr = e.addr;
            tb.host_data = e.data;
            next++;
            break;
        }
        tb.reset_n = reset_line;
        tb.dbg = getenv("V25_DBG_FROM") && t >= std::strtoull(getenv("V25_DBG_FROM"), nullptr, 0);
        tb.clk = 1; tb.eval();
        tb.clk = 0; tb.eval();
        if (tb.mismatch) {
            std::printf("MISMATCH at clock %llu: pc %05x bus %05x\n",
                        (unsigned long long)t, tb.pc, tb.bus_addr);
            auto show = [](const char *n, uint64_t v) {
                std::printf("  %s pc %05llx addr %05llx dout %02llx doe %llu rw %llu "
                            "mreq_n %llu mstb_n %llu iostb_n %llu halt %llu fault %llu idle %llu\n",
                            n, (v >> 36) & 0xfffff, (v >> 16) & 0xfffff, (v >> 8) & 0xff,
                            (v >> 7) & 1, (v >> 6) & 1, (v >> 5) & 1, (v >> 4) & 1,
                            (v >> 3) & 1, (v >> 2) & 1, (v >> 1) & 1, v & 1);
            };
            show("ref", tb.ref_state);
            show("dut", tb.dut_state);
            for (int k = 0; k < 16; k++)
                std::printf("  pc history %d: %05x\n", k, hist[(hist_n + k) & 15]);
            return 1;
        }
        if (tb.pc != last_pc) {
            hist[hist_n++ & 15] = tb.pc;
            last_pc = tb.pc;
        }
        if (tb.bus_write && !was_write) {
            writes++;
            if (tb.bus_addr <= 1) ym_writes++;
        }
        was_write = tb.bus_write;
        if (t % (limit / 50) == 0)
            std::printf("%llu of %llu clocks\n", (unsigned long long)t,
                        (unsigned long long)limit), std::fflush(stdout);
    }
    std::printf("identical for %llu clocks (%.2f s): %llu V25 bus writes "
                "(%llu to the YM2151), %u register-bank switches, internal "
                "RAM %u reads %u writes\n",
                (unsigned long long)limit, limit / 94.5e6,
                (unsigned long long)writes, (unsigned long long)ym_writes,
                tb.bank_switches, tb.iram_bus_reads, tb.iram_bus_writes);
    return 0;
}

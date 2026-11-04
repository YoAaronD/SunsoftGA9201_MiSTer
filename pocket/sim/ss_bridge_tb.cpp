// Unit test of pocket/rtl/pocket_ss_bridge.sv with a fake board: save read-out
// through the APF bridge timing, and loads in both orders. Run: pocket/scripts/ss_bridge_test.sh
#include "Vpocket_ss_bridge.h"
#include "verilated.h"
#include <cstdio>
#include <vector>
// fake board: ss_ready after save; reads return idx*3+1 after 6 clocks; writes stored
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* t = new Vpocket_ss_bridge;
    const double HS = 1e6/96.0/2.0, HA = 1e6/74.25/2.0; double ns = HS, na = HA;
    long a74 = 0; int pend = -1, cnt = 0, st = 0; std::vector<uint32_t> mem(32768, 0);
    auto edge_c = [&](int v) {
        t->clk = v;
        if (v) {   // fake board responds on rising core edges (before eval sees new inputs)
            t->ss_ack = 0;
            if (pend >= 0 && --cnt == 0) { t->ss_ack = 1; pend = -1; }
            if (t->ss_rd && pend < 0) { pend = t->ss_idx; cnt = 6; t->ss_rdata = t->ss_idx * 3 + 1; }
            if (t->ss_wr && pend < 0) { mem[t->ss_idx] = t->ss_wdata; pend = t->ss_idx; cnt = 2; }
            if (t->ss_save && st == 0) { st = 1; t->ss_active = 1; }
            else if (st >= 1 && st < 50) { if (++st == 50) t->ss_ready = 1; }
            if (t->ss_release) { t->ss_ready = 0; t->ss_active = 0; st = 0; }
            t->ss_done = 0;
            if (t->ss_load && st == 0) { st = 100; t->ss_active = 1; }
            if (t->ss_commit && st == 100) st = 101;
            else if (st > 100 && ++st == 300) { t->ss_done = 1; t->ss_active = 0; st = 0; }
        }
        t->eval();
    };
    auto tick = [&]() { for (int h = 0; h < 2; h++) { double tg = ns; while (na <= tg) { t->clk_74a = !t->clk_74a; if (t->clk_74a) a74++; t->eval(); na += HA; } ns += HS; edge_c(h); } };
    auto aw = [&](long n) { long a0 = a74; while (a74 - a0 < n) tick(); };
    t->reset = 1; for (int i = 0; i < 50; i++) tick(); t->reset = 0; for (int i = 0; i < 50; i++) tick();
    t->savestate_start = 1; while (!t->savestate_start_ack) tick(); t->savestate_start = 0;
    while (!t->savestate_start_ok) tick();
    int bad = 0;
    for (int w = 0; w < 32768; w++) {
        t->bridge_addr = 0x40000000u + 4u * w; aw(4);
        uint32_t d = t->rd_data; if (d != (uint32_t)(w * 3 + 1) && bad++ < 5) printf("word %d: %08X\n", w, d);
        t->bridge_rd = 1; aw(1); t->bridge_rd = 0; aw(36);
    }
    for (int i = 0; i < 100; i++) tick();
    printf("read-out: %d bad words, active after = %d\n", bad, (int)t->ss_active);
    for (int order = 0; order < 2; order++) {
        std::fill(mem.begin(), mem.end(), 0);
        auto words = [&]() { for (int w = 0; w < 32768; w++) {
            t->bridge_addr = 0x40000000u + 4u * w; t->bridge_wr_data = w ^ 0x5A5A0000u ^ order;
            aw(1); t->bridge_wr = 1; aw(1); t->bridge_wr = 0; aw(38); } };
        auto cmd = [&]() { t->savestate_load = 1; while (!t->savestate_load_ack) tick(); t->savestate_load = 0; };
        if (order == 0) { words(); cmd(); } else { cmd(); words(); }
        long n = 0; while (!t->savestate_load_ok && !t->savestate_load_err && n++ < 2000000) tick();
        int wbad = 0; for (int w = 0; w < 32768; w++) if (mem[w] != (uint32_t)(w ^ 0x5A5A0000u ^ order)) wbad++;
        printf("load (%s): ok=%d err=%d, %d words wrong\n", order ? "command first" : "words first", (int)t->savestate_load_ok, (int)t->savestate_load_err, wbad);
    }
    return 0;
}

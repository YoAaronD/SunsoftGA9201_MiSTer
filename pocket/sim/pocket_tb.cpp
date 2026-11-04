// End-to-end simulation of the Analogue Pocket port: the ROM stream arrives as
// APF bridge writes (74.25 MHz, one 32-bit word every --load-gap clk_74a
// cycles), goes through pocket_loader into the SDRAM model, the game boots,
// and the display frame buffer lives in two cellular-RAM models.
//
// usage: Vpocket_sim_top --stream FILE --game N --frames N
//          [--frames-out DIR --every N] [--direct] [--release-at CYCLE]
//          [--load-gap N] [--wav FILE]
// --release-at releases the game reset at that core-clock cycle (after the
// load), so a run can be lined up with scripts/sim_top.sh --release-at.
#include "Vpocket_sim_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

static std::vector<uint8_t> load(const std::string& p) {
    std::vector<uint8_t> d;
    FILE* f = fopen(p.c_str(), "rb");
    if (!f) { perror(p.c_str()); exit(1); }
    fseek(f, 0, SEEK_END); d.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(d.data(), 1, d.size(), f) != d.size()) exit(1);
    fclose(f);
    return d;
}

// SDRAM chip model, as in sim/top_tb.cpp
struct SdramModel {
    std::vector<uint16_t> mem = std::vector<uint16_t>(1u << 25, 0);
    uint16_t open_row[4] = {0, 0, 0, 0};
    std::deque<std::pair<int, uint16_t>> pending;
    long reads = 0, writes = 0, refreshes = 0;
    uint32_t index(int ba, uint16_t row, uint16_t col) {
        return ((uint32_t)ba << 23) | ((uint32_t)(row & 0x1fff) << 10) | (col & 0x3ff);
    }
    uint16_t cycle(Vpocket_sim_top* t) {
        int cmd = (t->SDRAM_nRAS << 2) | (t->SDRAM_nCAS << 1) | t->SDRAM_nWE;
        if (!t->SDRAM_nCS) {
            int ba = t->SDRAM_BA;
            uint16_t a = t->SDRAM_A;
            switch (cmd) {
            case 0b011: open_row[ba] = a & 0x1fff; break;
            case 0b101: {
                uint16_t col = a & 0x3ff;
                for (int i = 0; i < 4; i++) {
                    uint16_t c = (col & ~3) | ((col + i) & 3);
                    pending.push_back({4 + i, mem[index(ba, open_row[ba], c)]});
                }
                reads++;
                break;
            }
            case 0b100: {
                uint16_t col = a & 0x3ff;
                uint16_t& w = mem[index(ba, open_row[ba], col)];
                bool dqmh = (a >> 12) & 1, dqml = (a >> 11) & 1;
                uint16_t d = t->SDRAM_DQ_OUT;
                if (!dqmh) w = (w & 0x00ff) | (d & 0xff00);
                if (!dqml) w = (w & 0xff00) | (d & 0x00ff);
                writes++;
                break;
            }
            case 0b001: refreshes++; break;
            default: break;
            }
        }
        uint16_t dq = 0;
        for (auto& p : pending) p.first--;
        while (!pending.empty() && pending.front().first <= 0) {
            if (pending.front().first == 0) dq = pending.front().second;
            pending.pop_front();
        }
        return dq;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string frames_out, stream_path, wav_path;
    int game = 0, frames = 10, every = 30, load_gap = 75;
    int ss_at = 0;                 // --ss-test N: save state at frame N, run on, load it, compare
    std::string ss_out = ".";
    bool direct = false;
    uint64_t release_at = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--stream") && i + 1 < argc) stream_path = argv[++i];
        else if (!strcmp(argv[i], "--game") && i + 1 < argc) game = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--frames-out") && i + 1 < argc) frames_out = argv[++i];
        else if (!strcmp(argv[i], "--every") && i + 1 < argc) every = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--load-gap") && i + 1 < argc) load_gap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--release-at") && i + 1 < argc) release_at = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--wav") && i + 1 < argc) wav_path = argv[++i];
        else if (!strcmp(argv[i], "--direct")) direct = true;
        else if (!strcmp(argv[i], "--ss-test") && i + 1 < argc) ss_at = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ss-out") && i + 1 < argc) ss_out = argv[++i];
    }
    if (stream_path.empty()) { fprintf(stderr, "need --stream <file>\n"); return 1; }
    std::vector<uint8_t> stream = load(stream_path);
    while (stream.size() % 4) stream.push_back(0xff);       // the host sends whole words
    printf("ROM stream: %zu bytes, game %d, %s frame buffer\n", stream.size(), game,
           direct ? "direct" : "cellular RAM");

    auto* top = new Vpocket_sim_top;
    SdramModel sd;
    uint64_t cycle = 0;
    uint16_t dq_next = 0;

    std::vector<uint8_t> img(384 * 224 * 3, 0);
    std::vector<int16_t> audio;
    int vx = 0, vy = 0, prev_ce = 0, prev_hblank = 1, prev_vblank = 1, frame = 0;

    top->game_id = game;
    top->direct_scan = direct;
    top->in_inputs = 0xffff;
    top->in_system = 0x7f;
    top->dsw1 = 0xff;
    top->dsw2 = 0xbf;

    // two clocks: 96 MHz core (half period 5208.33 ps) and 74.25 MHz APF
    // (half period 6734.0 ps); edges are processed in time order
    const double HS = 1e6 / 96.0 / 2.0, HA = 1e6 / 74.25 / 2.0;
    double t = 0, next_s = HS, next_a = HA;
    // host side of the bridge (changes on clk_74a falling edges)
    size_t word = 0;
    long gap = 0;
    bool loading = false;
    long a74_cycles = 0;

    auto edge_a = [&]() {
        top->clk_74a = !top->clk_74a;
        if (!top->clk_74a) {                 // falling edge: host updates its outputs
            if (loading) top->bridge_wr = 0;
            if (loading && word * 4 < stream.size()) {
                if (gap == 0) {
                    size_t b = word * 4;
                    top->bridge_addr = (uint32_t)b;
                    top->bridge_wr_data = (stream[b] << 24) | (stream[b + 1] << 16) | (stream[b + 2] << 8) | stream[b + 3];
                    top->bridge_wr = 1;
                    word++;
                    gap = load_gap - 1;
                } else gap--;
            }
        } else a74_cycles++;
        top->eval();
    };
    auto tick = [&]() {                      // one core clock cycle
        for (int half = 0; half < 2; half++) {
            double target = next_s;
            while (next_a <= target) { t = next_a; next_a += HA; edge_a(); }
            t = target; next_s += HS;
            if (half == 0) { top->clk = 0; top->eval(); }
            else {
                top->SDRAM_DQ_IN = dq_next;
                top->clk = 1; top->eval();
            }
        }
        cycle++;
        dq_next = sd.cycle(top);
        if (prev_ce) {
            if (!top->hblank && !top->vblank) {
                if (vx < 384 && vy < 224) {
                    uint8_t* px = &img[(vy * 384 + vx) * 3];
                    px[0] = top->red; px[1] = top->green; px[2] = top->blue;
                }
                vx++;
            }
            if (top->hblank && !prev_hblank) { if (!top->vblank) vy++; vx = 0; }
            if (top->vblank) vy = 0;
            prev_hblank = top->hblank;
        }
        prev_ce = top->ce_pix;
    };

    // power-up
    top->sys_init = 1;
    top->reset = 1;
    top->running = 0;
    for (int i = 0; i < 100; i++) tick();
    top->sys_init = 0;
    for (int i = 0; i < 25000; i++) tick();          // SDRAM start-up, PSRAM configuration
    printf("frame buffer ready: %d, BCR written: %d\n", top->fb_ready, top->bcr_ok);

    // the host loads the data slot while the core is held in reset
    uint64_t dl_start = cycle;
    loading = true;
    while (word * 4 < stream.size()) tick();
    for (int i = 0; i < 4000; i++) tick();
    loading = false;
    printf("load: %zu bytes in %.1f ms (simulated), %ld SDRAM writes, ioctl_download=%d, overflow=%d\n",
           stream.size(), (cycle - dl_start) / 96000.0, sd.writes, top->ioctl_download, top->load_overflow);

    // compare the SDRAM image with what the MiSTer download would have written
    {
        auto wordat = [&](uint32_t byte_addr) {
            uint32_t w = byte_addr >> 1;
            int ba = (w >> 22) & 3; uint16_t row = (w >> 9) & 0x1fff;
            uint16_t col = ((w >> 24) & 1) << 9 | (w & 0x1ff);
            return sd.mem[sd.index(ba, row, col)];
        };
        long bad = 0;
        for (uint32_t i = 0; i < 0x80000; i++) {
            uint16_t exp = (stream[i] << 8) | stream[0x80000 + i];
            if (wordat(i * 2) != exp && bad++ < 5) printf("  prog word %05X: %04X != %04X\n", i, wordat(i * 2), exp);
        }
        uint32_t end = stream.size() < 0x510000 ? (uint32_t)stream.size() & ~1u : 0x510000;
        for (uint32_t b = 0x100000; b < end; b += 2) {
            uint16_t exp = stream[b] | (stream[b + 1] << 8);
            if (wordat(b) != exp && bad++ < 10) printf("  byte %06X: %04X != %04X\n", b, wordat(b), exp);
        }
        printf("SDRAM content check: %s (%ld mismatches)\n", bad ? "FAIL" : "ok", bad);
    }

    // host: reset exit
    top->running = 1;
    for (int i = 0; i < 64; i++) tick();
    if (release_at) {
        if (cycle > release_at) printf("note: --release-at %llu already passed (cycle %llu)\n",
                                       (unsigned long long)release_at, (unsigned long long)cycle);
        while (cycle < release_at) tick();
    }
    printf("ioctl_download=%d at release, cycle %llu\n", top->ioctl_download, (unsigned long long)cycle);
    top->reset = 0;

    // ---- save-state test through the APF bridge (pocket_ss_bridge.sv)
    auto a_wait = [&](long n) { long a0 = a74_cycles; while (a74_cycles - a0 < n) tick(); };
    auto run_frame = [&]() -> uint64_t {        // to the next start of vblank; frame hash
        for (;;) { tick(); bool e = top->vblank && !prev_vblank; prev_vblank = top->vblank; if (e) break; }
        uint64_t h = 1469598103934665603ull; for (auto b : img) { h ^= b; h *= 1099511628211ull; } return h;
    };
    auto save_img = [&](const std::string& p) {
        if (FILE* o = fopen(p.c_str(), "wb")) { fprintf(o, "P6\n384 224\n255\n"); fwrite(img.data(), 1, img.size(), o); fclose(o); }
    };
    if (ss_at) {
        const int N = 32768, M = 60;
        for (int f = 0; f < ss_at; f++) { run_frame(); if ((f + 1) % 100 == 0) { printf("frame %d\n", f + 1); fflush(stdout); } }
        // 1) save: command, then read the blob back word by word
        uint64_t c0 = cycle;
        top->savestate_start = 1;
        while (!top->savestate_start_ack) tick();
        top->savestate_start = 0;
        while (!top->savestate_start_ok && !top->savestate_start_err) { tick(); if (cycle - c0 > 8000000) { printf("FAIL: save never ok\n"); return 1; } }
        if (top->savestate_start_err) { printf("FAIL: save error\n"); return 1; }
        printf("save: ok after %.2f ms\n", (cycle - c0) / 96000.0);
        std::vector<uint32_t> blob(N);
        uint64_t r0 = cycle;
        for (int w = 0; w < N; w++) {
            top->bridge_addr = 0x40000000u + 4u * w;
            a_wait(4);                          // the bridge samples 4 cycles after the address
            blob[w] = top->ss_bridge_rd_data;
            top->bridge_rd = 1; a_wait(1); top->bridge_rd = 0;
            a_wait(36);                         // the next word's address over SPI
        }
        printf("save: %d words read in %.1f ms; header %08X %08X %08X %08X\n", N, (cycle - r0) / 96000.0, blob[0], blob[1], blob[2], blob[3]);
        if (FILE* o = fopen((ss_out + "/pocket_blob.bin").c_str(), "wb")) { fwrite(blob.data(), 4, N, o); fclose(o); }
        uint64_t q0 = cycle;
        while (top->ss_active) { tick(); if (cycle - q0 > 4000000) { printf("FAIL: game did not resume\n"); return 1; } }
        printf("save: game resumed %.2f ms after the last read\n", (cycle - q0) / 96000.0);
        std::vector<uint64_t> ref(M);
        for (int f = 0; f < M; f++) ref[f] = run_frame();
        save_img(ss_out + "/pocket_ref_end.ppm");
        // 2) run on for a while, then load the blob: words first, then the command
        for (int f = 0; f < 150; f++) run_frame();
        save_img(ss_out + "/pocket_before_load.ppm");
        uint64_t l0 = cycle;
        for (int w = 0; w < N; w++) {
            top->bridge_addr = 0x40000000u + 4u * w; top->bridge_wr_data = blob[w];
            a_wait(1); top->bridge_wr = 1; a_wait(1); top->bridge_wr = 0; a_wait(38);
        }
        top->savestate_load = 1;
        while (!top->savestate_load_ack) tick();
        top->savestate_load = 0;
        while (!top->savestate_load_ok && !top->savestate_load_err) { tick(); if (cycle - l0 > 400000000) { printf("FAIL: load never ok\n"); return 1; } }
        printf("load: %s after %.1f ms\n", top->savestate_load_ok ? "ok" : "ERROR", (cycle - l0) / 96000.0);
        int nd = 0, first = -1, last = -1;
        for (int f = 0; f < M; f++) { uint64_t h = run_frame(); if (h != ref[f]) { nd++; if (first < 0) first = f + 1; last = f + 1; }
            if (f == 3) save_img(ss_out + "/pocket_load_f4.ppm"); }
        save_img(ss_out + "/pocket_load_end.ppm");
        printf("after load: %d/%d frames differ from the run after the save (first %d, last %d)\n", nd, M, first, last);
        printf("cellular RAM protocol errors: %d\n", top->cram_errors);
        return 0;
    }

    uint64_t run_start = cycle;
    while (frame < frames) {
        tick();
        if (!wav_path.empty() && cycle % 2000 == 0) audio.push_back((int16_t)top->snd);
        if (top->vblank && !prev_vblank) {
            frame++;
            if (!frames_out.empty() && frame % every == 0) {
                char path[512];
                snprintf(path, sizeof path, "%s/frame_%05d.ppm", frames_out.c_str(), frame);
                if (FILE* o = fopen(path, "wb")) {
                    fprintf(o, "P6\n384 224\n255\n");
                    fwrite(img.data(), 1, img.size(), o);
                    fclose(o);
                }
            }
        }
        prev_vblank = top->vblank;
    }
    printf("ran %d frames (%.1f ms); SDRAM reads %ld, refreshes %ld\n",
           frames, (cycle - run_start) / 96000.0, sd.reads, sd.refreshes);
    printf("cellular RAM: %d words written, %d read, %d protocol errors\n",
           top->cram_words_w, top->cram_words_r, top->cram_errors);
    printf("vblank copies: %d, blitter hold %d..%d clocks (MiSTer: 86016)\n",
           top->copies, top->copies ? top->copy_min : 0, top->copy_max);

    if (!wav_path.empty()) {
        FILE* w = fopen(wav_path.c_str(), "wb");
        uint32_t data_bytes = audio.size() * 2, rate = 48000, byte_rate = rate * 2, riff = 36 + data_bytes, fl = 16;
        uint16_t pcm = 1, ch = 1, align = 2, bits = 16;
        fwrite("RIFF", 1, 4, w); fwrite(&riff, 4, 1, w); fwrite("WAVEfmt ", 1, 8, w); fwrite(&fl, 4, 1, w);
        fwrite(&pcm, 2, 1, w); fwrite(&ch, 2, 1, w); fwrite(&rate, 4, 1, w); fwrite(&byte_rate, 4, 1, w);
        fwrite(&align, 2, 1, w); fwrite(&bits, 2, 1, w); fwrite("data", 1, 4, w); fwrite(&data_bytes, 4, 1, w);
        fwrite(audio.data(), 2, audio.size(), w);
        fclose(w);
    }
    delete top;
    return 0;
}

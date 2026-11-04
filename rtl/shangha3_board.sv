// Sunsoft GA9201 board - top level, for three games selected by game_id:
//   0 Shanghai III (1993, SUN04C)        68000, YM2149, OKI M6295 on the 68000 bus
//   1 Hebereke no Popoon (1994, SUN-06)  68000 + Z80 sound CPU, YM3438, OKI (banked)
//   2 Blocken (1994, KID-07)             as heberpop, with a moved I/O page,
//                                        a third button and a 4-bank OKI ROM
//
// Behavioural reference: MAME src/mame/sunelectronics/shangha3.cpp
// (BSD-3-Clause, Nicola Salmoria). No MAME code is included here.
//
// Clocking: everything runs from one 96 MHz clock (2 x the board's 48 MHz
// crystal) using clock enables:
//   68000   16 MHz   (48/3)  -> phi enable every 3 clocks
//   pixel    8 MHz   (48/6)  -> every 12 clocks
//   YM2149 1.5 MHz   (48/32) -> every 64 clocks
//
// STATUS
//   done : 68000, memory map, work RAM, palette RAM, inputs, DIPs via YM2149,
//          protection read, vblank IRQ4 + ack, video timing,
//          GA9201 blitter, frame buffers, palette output
//          OKI M6295 sound and mixer
//   ROMs are reached through simple request ports; the MiSTer top level
//   connects them to SDRAM.

module shangha3_board (
    input  logic        clk,          // 96 MHz
    input  logic        reset,
    input  logic [1:0]  game_id,      // 0 shangha3j, 1 heberpop, 2 blocken (from the MRA)
    input  logic        vid_reset,    // video timing + display path: power-up only, so sync never stops
    input  logic        pause,        // freeze CPU and sound (OSD open); video keeps running
    input  logic        direct_scan,  // Pocket fallback: scan out the draw buffer (0 on the MiSTer)
    // save states (all 0 = unused): see "Save states" at the end
    input  logic        ss_save,      // pulse: freeze at a clean point and dump the 68000
    input  logic        ss_load,      // pulse: a load starts (68000 stopped at once)
    input  logic        ss_commit,    // pulse: every word of the load has been written
    input  logic        ss_release,   // pulse: the saved state has been read out; resume
    output logic        ss_ready,     // save: state can be read (until ss_release)
    output logic        ss_done,      // pulse: load applied, game running again
    output logic        ss_err,       // pulse: save refused (too early) / load rejected
    output logic        ss_reset_req, // pulse: rejected load already overwrote RAM: reboot
    output logic        ss_active,    // a save or load is in progress
    input  logic        ss_rd,        // pulse: read 32-bit state word ss_idx
    input  logic        ss_wr,        // pulse: write ss_wdata to state word ss_idx
    input  logic [14:0] ss_idx,
    input  logic [31:0] ss_wdata,
    output logic [31:0] ss_rdata,
    output logic        ss_ack,       // pulse: ss_rdata valid / write done
    input  logic [2:0]  snd_balance,  // OSD OKI vs YM2149 balance (0 = PCB), see shangha3_mixer.sv

    // 68000 ROM reads, as an SDRAM word address (see shangha3_mem.sv):
    // program (up to 1 MB) at 000000, graphics ROM (heberpop/blocken read it
    // at 800000-B7FFFF) at 110000
    output logic [22:1] prog_addr,
    output logic        prog_cs,
    input  logic [15:0] prog_data,
    input  logic        prog_ok,

    // Z80 program ROM (heberpop/blocken)
    output logic [15:0] z80_rom_addr,
    output logic        z80_rom_cs,
    input  logic [7:0]  z80_rom_data,
    input  logic        z80_rom_ok,

    // controls, all active low as on the PCB
    input  logic [15:0] in_inputs,    // INPUTS: P1 [5:0] R,L,D,U,B1,B2, [6] B3; P2 [13:8], [14] B3 (bits 7/15 set here)
    input  logic [6:0]  in_system,    // SYSTEM bits 6..0 (shangha3 bit 7 = vblank, added here)
    input  logic [7:0]  dsw1,         // SW1: shangha3 YM2149 port A; heberpop/blocken DSW low byte
    input  logic [7:0]  dsw2,         // SW2: shangha3 YM2149 port B; heberpop/blocken DSW high byte

    // video
    output logic        ce_pix,
    output logic        hsync,
    output logic        vsync,
    output logic        hblank,
    output logic        vblank,
    output logic        vblank_next,      // vblank of the next line (CRT Adjust glue)
    output logic [7:0]  red,
    output logic [7:0]  green,
    output logic [7:0]  blue,

    // graphics ROM (2 MB / 3.5 MB) for the blitter: one 8-byte tile row per request
    output logic        gfx_req,
    output logic [18:0] gfx_addr,
    input  logic        gfx_ack,
    input  logic [63:0] gfx_data,

    // DDR3 for the display frame buffer (MiSTer DDRAM port, Avalon-MM)
    input  logic        ddr_busy,
    output logic [7:0]  ddr_burstcnt,
    output logic [28:0] ddr_addr,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,
    output logic        ddr_rd,
    output logic [63:0] ddr_din,
    output logic [7:0]  ddr_be,
    output logic        ddr_we,

    // audio
    output logic [9:0]  psg_snd,          // YM2149 raw (unsigned)
    output logic signed [13:0] oki_snd,   // OKI M6295 raw (signed)
    output logic signed [15:0] snd,       // mixed, signed 16-bit

    // OKI sample ROM (up to 512 KB, after the bank logic): rom_ok must be
    // high only when rom_data matches oki_rom_addr
    output logic [18:0] oki_rom_addr,
    input  logic [7:0]  oki_rom_data,
    input  logic        oki_rom_ok,

    // debug / simulation visibility
    output logic        dbg_blit_go,
    output logic        dbg_irq_ack,
    output logic [15:0] dbg_gfxlist,
    output logic        dbg_flip,
    output logic [7:0]  dbg_coinctrl,
    output logic        dbg_oki_wr,
    output logic [7:0]  dbg_oki_data,
    output logic [23:0] dbg_cpu_addr,
    output logic        dbg_cpu_cyc_start,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_dout,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_cpu_dtack,
    output logic        dbg_blit_busy,
    output logic        dbg_ram_stall,     // CPU write waiting for the blitter
    output logic        dbg_latch_wr,      // heberpop/blocken: 68000 sound latch write
    output logic        dbg_z80_io_wr,     // heberpop/blocken: Z80 I/O write
    output logic [7:0]  dbg_z80_io_addr,
    output logic [7:0]  dbg_z80_io_data
);

    wire g_s3  = (game_id == 2'd0);            // Shanghai III
    wire g_hbp = (game_id == 2'd1);            // Hebereke no Popoon
    wire g_blk = (game_id == 2'd2);            // Blocken
    wire g_new = !g_s3;                        // the Z80 boards

    // ------------------------------------------------------------------
    // Clock enables
    // ------------------------------------------------------------------
    logic [1:0] cpu_div;
    logic       cpu_phase;
    logic       en_phi1, en_phi2;
    logic [3:0] pix_div;
    logic [5:0] psg_div;
    logic       ce_psg;

    // pause: the CPU and sound clock enables stop (the CPU halts mid-cycle
    // and resumes exactly where it was); video timing, the frame-buffer copy
    // and the blitter keep running, so the screen holds the last picture.
    logic pause_s1, pause_q;
    logic ss_snd_stop;                    // save/load in progress: sound frozen (see "Save states")
    logic ss_pix_stop;                    // save/load: pixel clock (video timing) stopped
    logic ss_cpu_clk;                     // save/load: 68000 clocked even while paused
    wire  cpu_run = !pause_q || ss_cpu_clk;
    logic        ss_apply;                 // one clock: load the registers below from a loaded state
    logic [31:0] ss_hdr4, ss_hdr5, ss_hdr6;
    logic        ss_irq7;
    logic        ss_ovr;
    logic [15:0] ss_dout;
    wire  snd_pause = pause_q || ss_snd_stop;
    always_ff @(posedge clk) begin
        pause_s1 <= pause;                // from the menu: synchronise
        pause_q  <= pause_s1;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            cpu_div   <= '0;
            cpu_phase <= 1'b0;
            psg_div   <= '0;
        end else begin
            if (cpu_run) begin
                cpu_div <= (cpu_div == 2'd2) ? 2'd0 : cpu_div + 2'd1;
                if (cpu_div == 2'd2) cpu_phase <= ~cpu_phase;
            end
            if (!snd_pause) psg_div <= psg_div + 6'd1;
        end
    end

    // The pixel clock and video timing run through board resets and ROM
    // downloads (only vid_reset stops them), so a CRT never loses sync.
    always_ff @(posedge clk) begin
        if (vid_reset)          pix_div <= '0;
        else if (!ss_pix_stop)  pix_div <= (pix_div == 4'd11) ? 4'd0 : pix_div + 4'd1;
    end

    assign en_phi1 = (cpu_div == 2'd2) && !cpu_phase && cpu_run;
    assign en_phi2 = (cpu_div == 2'd2) &&  cpu_phase && cpu_run;
    assign ce_pix  = (pix_div == 4'd11) && !ss_pix_stop;
    assign ce_psg  = (psg_div == 6'd63) && !snd_pause;

    // ------------------------------------------------------------------
    // Video timing
    // ------------------------------------------------------------------
    logic [8:0] hcnt, vcnt;
    logic       vblank_start;

    shangha3_video_timing u_timing (
        .clk, .reset(vid_reset), .ce_pix,
        .hcnt, .vcnt, .hblank, .vblank, .hsync, .vsync, .vblank_start, .vblank_next
    );


    // ------------------------------------------------------------------
    // 68000 (fx68k)
    // ------------------------------------------------------------------
    logic        cpu_rw, cpu_as_n, cpu_uds_n, cpu_lds_n;
    logic [2:0]  cpu_fc;
    logic [23:1] cpu_eab;
    logic [15:0] cpu_dout, cpu_din;
    logic        cpu_dtack_n, cpu_vpa_n;
    logic [2:0]  cpu_ipl_n;
    logic        ss_cpu_reset;

    fx68k u_cpu (
        .clk       (clk),
        .HALTn     (1'b1),
        .extReset  (reset || ss_cpu_reset),
        .pwrUp     (reset || ss_cpu_reset),
        .enPhi1    (en_phi1),
        .enPhi2    (en_phi2),
        .eRWn      (cpu_rw),
        .ASn       (cpu_as_n),
        .LDSn      (cpu_lds_n),
        .UDSn      (cpu_uds_n),
        .E         (),
        .VMAn      (),
        .FC0       (cpu_fc[0]),
        .FC1       (cpu_fc[1]),
        .FC2       (cpu_fc[2]),
        .BGn       (),
        .oRESETn   (),
        .oHALTEDn  (),
        .DTACKn    (cpu_dtack_n),
        .VPAn      (cpu_vpa_n),
        .BERRn     (1'b1),
        .BRn       (1'b1),
        .BGACKn    (1'b1),
        .IPL0n     (cpu_ipl_n[0]),
        .IPL1n     (cpu_ipl_n[1]),
        .IPL2n     (cpu_ipl_n[2]),
        .iEdb      (cpu_din),
        .oEdb      (cpu_dout),
        .eab       (cpu_eab)
    );

    wire [23:0] cpu_addr = {cpu_eab, 1'b0};
    wire        cpu_uds  = !cpu_uds_n;
    wire        cpu_lds  = !cpu_lds_n;
    wire        cpu_iack = !cpu_as_n && (cpu_fc == 3'b111);
    wire        cpu_cyc  = !cpu_as_n && (cpu_uds || cpu_lds) && !cpu_iack;
    // On writes the 68000 asserts UDS/LDS one state later than AS. DTACK
    // timing counts from AS so writes don't pick up an extra wait state;
    // the actual write strobes still wait for UDS/LDS (cpu_cyc).
    wire        cpu_as_cyc = !cpu_as_n && !cpu_iack;

    logic cpu_cyc_d;
    always_ff @(posedge clk) cpu_cyc_d <= reset ? 1'b0 : cpu_cyc;
    wire cyc_start = cpu_cyc && !cpu_cyc_d;

    // ------------------------------------------------------------------
    // Address decode (MAME shangha3_state / heberpop_state / blocken_state
    // ::program_map)
    //                 shangha3      heberpop      blocken
    //   program ROM   000000-07FFFF 000000-0FFFFF 000000-0FFFFF (FF above 03FFFF)
    //   palette       100000-100FFF 100000-100FFF 200000-200FFF
    //   I/O page      2000xx        2000xx        1000xx
    //   graphics ROM  -             800000-B7FFFF 800000-B7FFFF
    // ------------------------------------------------------------------
    wire sel_rom  = g_s3 ? (cpu_addr[23:19] == 5'h00) : (cpu_addr[23:20] == 4'h0);
    wire sel_pal  = cpu_addr[23:12] == (g_blk ? 12'h200 : 12'h100);
    wire sel_io   = cpu_addr[23:8]  == (g_blk ? 16'h1000 : 16'h2000);
    wire sel_ram  = cpu_addr[23:16] == 8'h30;           // 300000-30FFFF
    wire sel_flip = cpu_addr[23:1]  == 23'h1A0000;      // 340000/1
    wire sel_gfxl = cpu_addr[23:1]  == 23'h1B0000;      // 360000/1
    wire sel_grom = g_new && (cpu_addr[23:22] == 2'b10) &&           // 800000-B7FFFF
                    (cpu_addr[21:0] < 22'h380000);

    wire [6:0] io_reg = cpu_addr[7:1];
    localparam logic [6:0] IO_INPUTS = 7'h00,  // 200000
                           IO_SYSTEM = 7'h01,  // 200002
                           IO_DSW    = 7'h02,  // ..0004 (heberpop/blocken)
                           IO_LATCH  = 7'h07,  // ..000F (heberpop/blocken, odd byte)
                           IO_BLIT   = 7'h04,  // 200008
                           IO_IRQACK = 7'h05,  // 20000A
                           IO_COIN   = 7'h06,  // 20000C (even byte)
                           IO_AY_RD  = 7'h0F,  // 20001F
                           IO_AY_DAT = 7'h17,  // 20002F
                           IO_AY_ADR = 7'h1F,  // 20003F
                           IO_PROT   = 7'h27,  // 20004E
                           IO_OKI    = 7'h37;  // 20006F

    wire io_wr = cyc_start && sel_io && !cpu_rw;
    wire io_rd = cyc_start && sel_io &&  cpu_rw;

    // ------------------------------------------------------------------
    // Program ROM and (heberpop/blocken) graphics ROM reads, via SDRAM
    // ------------------------------------------------------------------
    // graphics ROM: CPU byte offset o = addr - 800000 -> SDRAM 110000 + o
    wire [22:0] grom_sdram = 23'h110000 + {1'b0, cpu_addr[21:0]};
    assign prog_addr = sel_grom ? grom_sdram[22:1] : {2'b00, cpu_addr[20:1]};
    assign prog_cs   = cpu_cyc && (sel_rom || sel_grom) && cpu_rw;

    // ------------------------------------------------------------------
    // Work / graphics RAM 300000-30FFFF (32K x 16)
    // The blitter will need a second port on this later.
    // ------------------------------------------------------------------
    logic [7:0]  ram_hi [0:32767];
    logic [7:0]  ram_lo [0:32767];
    logic [15:0] ram_q;
    // the save-state engine owns the CPU side while the 68000 is held in reset
    logic        ss_mem;               // engine owns the RAM/palette CPU ports
    logic [15:0] ss_maddr;             // engine RAM/palette word address
    logic        ss_mwe_ram, ss_mwe_pal;
    logic [15:0] ss_mwd;
    wire  [14:0] ram_a  = ss_mem ? ss_maddr[14:0] : cpu_addr[15:1];
    logic        ram_we;       // driven below, after the blitter arbitration logic

    // The write itself lands one clock after ram_we (registered address, data
    // and byte enables), so the blitter-conflict compare doesn't have to reach
    // the 64 RAM blocks' write enables in one 96 MHz clock (timing). The bus
    // cycle and its DTACK are unchanged; nothing reads the word within a clock.
    logic        ram_we_hi_q, ram_we_lo_q;
    logic [14:0] ram_wa_q;
    logic [15:0] ram_wd_q;
    always_ff @(posedge clk) begin
        ram_we_hi_q <= (ram_we && cpu_uds) || ss_mwe_ram;
        ram_we_lo_q <= (ram_we && cpu_lds) || ss_mwe_ram;
        ram_wa_q    <= ram_a;
        ram_wd_q    <= ss_mwe_ram ? ss_mwd : cpu_dout;
    end

    // second (read-only) port for the blitter
    logic [14:0] blit_ram_addr;
    logic [15:0] blit_ram_q;

`ifdef POCKET
    // Analogue Pocket: one true-dual-port memory per byte lane instead of the
    // two copies Quartus builds from the code below. Port A serves the CPU:
    // in the clock where a write lands it is addressed by the write, so ram_q
    // that clock is not the CPU read address. The CPU is in that write's bus
    // cycle then and doesn't sample ram_q (the write lands one clock after the
    // cycle starts; reads latch ram_q at the end of a cycle).
    wire        ram_wr_now = ram_we_hi_q || ram_we_lo_q;
    wire [14:0] ram_pa     = ram_wr_now ? ram_wa_q : ram_a;
    pocket_tdp_ram #(.AW(15), .DW(8)) u_ram_hi (
        .clk, .a_addr(ram_pa), .a_we(ram_we_hi_q), .a_d(ram_wd_q[15:8]), .a_q(ram_q[15:8]),
        .b_addr(blit_ram_addr), .b_q(blit_ram_q[15:8])
    );
    pocket_tdp_ram #(.AW(15), .DW(8)) u_ram_lo (
        .clk, .a_addr(ram_pa), .a_we(ram_we_lo_q), .a_d(ram_wd_q[7:0]), .a_q(ram_q[7:0]),
        .b_addr(blit_ram_addr), .b_q(blit_ram_q[7:0])
    );
`else
    always_ff @(posedge clk) begin
        if (ram_we_hi_q) ram_hi[ram_wa_q] <= ram_wd_q[15:8];
        if (ram_we_lo_q) ram_lo[ram_wa_q] <= ram_wd_q[7:0];
        ram_q <= {ram_hi[ram_a], ram_lo[ram_a]};
    end
    always_ff @(posedge clk) blit_ram_q <= {ram_hi[blit_ram_addr], ram_lo[blit_ram_addr]};
`endif

    // ------------------------------------------------------------------
    // Palette RAM 100000-100FFF (2048 x 16, RGBx_555)
    // ------------------------------------------------------------------
    logic [7:0]  pal_hi [0:2047];
    logic [7:0]  pal_lo [0:2047];
    logic [15:0] pal_q;
    wire  [10:0] pal_a  = ss_mem ? ss_maddr[10:0] : cpu_addr[11:1];
    wire         pal_we = cyc_start && sel_pal && !cpu_rw;
    wire         pal_we_hi = (pal_we && cpu_uds) || ss_mwe_pal;
    wire         pal_we_lo = (pal_we && cpu_lds) || ss_mwe_pal;
    wire  [15:0] pal_wd    = ss_mwe_pal ? ss_mwd : cpu_dout;

    // second (read-only) port for video scan-out
    logic [10:0] vid_pal_addr;
    logic [15:0] vid_pal_q;

`ifdef POCKET
    // Analogue Pocket: one true-dual-port memory per byte lane (see the work
    // RAM above); pal_q in a write clock is not used (the CPU is writing).
    pocket_tdp_ram #(.AW(11), .DW(8)) u_pal_hi (
        .clk, .a_addr(pal_a), .a_we(pal_we_hi), .a_d(pal_wd[15:8]), .a_q(pal_q[15:8]),
        .b_addr(vid_pal_addr), .b_q(vid_pal_q[15:8])
    );
    pocket_tdp_ram #(.AW(11), .DW(8)) u_pal_lo (
        .clk, .a_addr(pal_a), .a_we(pal_we_lo), .a_d(pal_wd[7:0]), .a_q(pal_q[7:0]),
        .b_addr(vid_pal_addr), .b_q(vid_pal_q[7:0])
    );
`else
    always_ff @(posedge clk) begin
        if (pal_we_hi) pal_hi[pal_a] <= pal_wd[15:8];
        if (pal_we_lo) pal_lo[pal_a] <= pal_wd[7:0];
        pal_q <= {pal_hi[pal_a], pal_lo[pal_a]};
    end
    always_ff @(posedge clk) vid_pal_q <= {pal_hi[vid_pal_addr], pal_lo[vid_pal_addr]};
`endif

    // ------------------------------------------------------------------
    // Blitter + frame buffers
    // ------------------------------------------------------------------
    logic [16:0] fb_addr;
    logic        fb_we;
    logic [11:0] fb_wdata, fb_rdata;
    logic        fb_copying;
    logic        blit_busy;
    logic        blit_px_step;
    logic [18:0] blit_scan_from;
    logic [13:0] blit_tm_from;

    shangha3_blitter u_blitter (
        .clk, .reset,
        .start     (dbg_blit_go),
        .gfxlist   (dbg_gfxlist),
        .flip      (dbg_flip),
        .shadow_en (g_s3),             // Shanghai III uses pen-14 shadows; heberpop/blocken don't
        .big_gfx   (g_new),            // 3.5 MB graphics ROM on heberpop/blocken
        .hold      (fb_copying),
        .busy      (blit_busy),
        .px_step   (blit_px_step),
        .scan_from (blit_scan_from),
        .tm_from   (blit_tm_from),
        .ram_addr  (blit_ram_addr),
        .ram_q     (blit_ram_q),
        .gfx_req, .gfx_addr, .gfx_ack, .gfx_data,
        .fb_addr, .fb_we, .fb_wdata, .fb_rdata
    );

    shangha3_video u_video (
        .clk, .reset(vid_reset), .clear(reset), .ce_pix, .hcnt, .vcnt, .vblank_start, .direct_scan,
        .fb_addr, .fb_we, .fb_wdata, .fb_rdata,
        .copying   (fb_copying),
        .pal_addr  (vid_pal_addr),
        .pal_q     (vid_pal_q),
        .red, .green, .blue,
        .ddr_busy, .ddr_burstcnt, .ddr_addr, .ddr_dout, .ddr_dout_ready,
        .ddr_rd, .ddr_din, .ddr_be, .ddr_we
    );

    // ------------------------------------------------------------------
    // Protection at 20004E: MAME returns this sequence on successive reads
    // ------------------------------------------------------------------
    logic [3:0] prot_cnt;
    logic [3:0] prot_q;
    function automatic logic [3:0] prot_value(input logic [3:0] n);
        case (n)
            4'd0: prot_value = 4'h0;  4'd1: prot_value = 4'h1;
            4'd2: prot_value = 4'h3;  4'd3: prot_value = 4'h7;
            4'd4: prot_value = 4'hf;  4'd5: prot_value = 4'he;
            4'd6: prot_value = 4'hc;  4'd7: prot_value = 4'h8;
            default: prot_value = 4'h0;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            prot_cnt <= '0;
            prot_q   <= '0;
        end else if (ss_apply) begin
            {prot_cnt, prot_q} <= ss_hdr5[7:0];
        end else if (io_rd && io_reg == IO_PROT) begin
            prot_q   <= prot_value(prot_cnt);
            prot_cnt <= (prot_cnt == 4'd8) ? 4'd0 : prot_cnt + 4'd1;
        end
    end

    // ------------------------------------------------------------------
    // Simple write registers
    // ------------------------------------------------------------------
    logic irq4;
    logic latch_wr;
    logic [7:0] latch_din;

    always_ff @(posedge clk) begin
        dbg_blit_go <= 1'b0;
        dbg_irq_ack <= 1'b0;
        dbg_oki_wr  <= 1'b0;
        latch_wr    <= 1'b0;
        if (reset) begin
            dbg_gfxlist  <= '0;
            dbg_flip     <= 1'b0;
            dbg_coinctrl <= '0;
            dbg_oki_data <= '0;
            latch_din    <= '0;
            irq4         <= 1'b0;
        end else begin
            if (vblank_start) irq4 <= 1'b1;
            if (io_wr) begin
                case (io_reg)
                    IO_BLIT:   dbg_blit_go <= 1'b1;
                    IO_IRQACK: begin dbg_irq_ack <= 1'b1; irq4 <= 1'b0; end
                    // coin control: shangha3 even byte (..0C); heberpop/blocken odd byte (..0D),
                    // where it also selects the OKI ROM bank
                    IO_COIN:   if (g_s3 ? cpu_uds : cpu_lds) dbg_coinctrl <= g_s3 ? cpu_dout[15:8] : cpu_dout[7:0];
                    IO_OKI:    if (g_s3 && cpu_lds) begin dbg_oki_wr <= 1'b1; dbg_oki_data <= cpu_dout[7:0]; end
                    IO_LATCH:  if (g_new && cpu_lds) begin latch_wr <= 1'b1; latch_din <= cpu_dout[7:0]; end
                    default: ;
                endcase
            end
            if (cyc_start && !cpu_rw && sel_flip && cpu_lds) dbg_flip <= cpu_dout[7];
            if (cyc_start && !cpu_rw && sel_gfxl) begin
                if (cpu_uds) dbg_gfxlist[15:8] <= cpu_dout[15:8];
                if (cpu_lds) dbg_gfxlist[7:0]  <= cpu_dout[7:0];
            end
            if (ss_apply) begin
                {irq4, dbg_flip, dbg_gfxlist, dbg_coinctrl} <= ss_hdr4[25:0];
                {dbg_oki_data, latch_din}                   <= ss_hdr5[23:8];
            end
        end
    end

    assign cpu_ipl_n = ss_irq7 ? 3'b000 : irq4 ? 3'b011 : 3'b111;   // level 4 -> IPL2n=0

    // ------------------------------------------------------------------
    // YM2149 (jt49) - also reads DIP switches on its ports A/B
    // ------------------------------------------------------------------
    logic       ay_bdir, ay_bc1;
    logic [7:0] ay_dout;

    always_ff @(posedge clk) begin
        if (reset) begin
            {ay_bdir, ay_bc1} <= 2'b00;
        end else if (io_wr && io_reg == IO_AY_ADR && cpu_lds) begin
            {ay_bdir, ay_bc1} <= 2'b11;              // latch address
        end else if (io_wr && io_reg == IO_AY_DAT && cpu_lds) begin
            {ay_bdir, ay_bc1} <= 2'b10;              // write data
        end else if (cpu_cyc && sel_io && cpu_rw && io_reg == IO_AY_RD) begin
            {ay_bdir, ay_bc1} <= 2'b01;              // read data
        end else begin
            {ay_bdir, ay_bc1} <= 2'b00;
        end
    end

    jt49_bus u_ay (
        .rst_n   (!reset),
        .clk     (clk),
        .clk_en  (ce_psg),
        .bdir    (ay_bdir),
        .bc1     (ay_bc1),
        .din     (cpu_dout[7:0]),
        .sel     (1'b1),
        .dout    (ay_dout),
        .sound   (psg_snd),
        .A       (), .B(), .C(),
        .sample  (),
        .IOA_in  (dsw1), .IOA_out(), .IOA_oe(),
        .IOB_in  (dsw2), .IOB_out(), .IOB_oe()
    );

    // ------------------------------------------------------------------
    // OKI M6295 (jt6295) at 1.056 MHz, pin 7 high (sample rate = clk/132 = 8 kHz)
    // 96 MHz * 11/1000 = 1.056 MHz exactly
    // ------------------------------------------------------------------
    logic [9:0] oki_acc;
    logic       ce_oki;
    always_ff @(posedge clk) begin
        if (reset) begin
            oki_acc <= '0;
            ce_oki  <= 1'b0;
        end else if (snd_pause) begin
            ce_oki  <= 1'b0;
        end else if (oki_acc + 10'd11 >= 10'd1000) begin
            oki_acc <= oki_acc + 10'd11 - 10'd1000;
            ce_oki  <= 1'b1;
        end else begin
            oki_acc <= oki_acc + 10'd11;
            ce_oki  <= 1'b0;
        end
    end

    logic [7:0]  oki_dout;
    logic        z_oki_wrn;
    logic [7:0]  z_oki_din;
    // shangha3: the 68000 writes the OKI at 20006F; heberpop/blocken: the Z80 at port 80
    wire oki_wrn = g_s3 ? !(cpu_cyc && sel_io && !cpu_rw && io_reg == IO_OKI && cpu_lds) : z_oki_wrn;
    wire [7:0] oki_din = g_s3 ? cpu_dout[7:0] : z_oki_din;

    // OKI ROM banks, selected by the 68000's coin-control write:
    //   heberpop: bit 3 picks which 256 KB half of the 512 KB ROM the OKI sees
    //   blocken : OKI 00000-1FFFF fixed; 20000-3FFFF = ROM bank * 20000 (bits 5:4)
    logic [17:0] oki_chip_addr;
    always_comb begin
        if (g_hbp)
            oki_rom_addr = {dbg_coinctrl[3], oki_chip_addr};
        else if (g_blk && oki_chip_addr[17])
            oki_rom_addr = {dbg_coinctrl[5:4], oki_chip_addr[16:0]};
        else
            oki_rom_addr = {1'b0, oki_chip_addr};
    end

    jt6295 #(.INTERPOL(0)) u_oki (
        .rst      (reset),
        .clk      (clk),
        .cen      (ce_oki),
        .ss       (1'b1),
        .wrn      (oki_wrn),
        .din      (oki_din),
        .dout     (oki_dout),
        .rom_addr (oki_chip_addr),
        .rom_data (oki_rom_data),
        .rom_ok   (oki_rom_ok),
        .sound    (oki_snd),
        .sample   ()
    );

    // ------------------------------------------------------------------
    // heberpop/blocken sound CPU section: Z80, YM3438, sound latch
    // (held in reset on Shanghai III)
    // ------------------------------------------------------------------
    logic signed [15:0] fm_left, fm_right;
    ga9201_sound u_snd (
        .clk, .reset(reset || g_s3), .pause(snd_pause),
        .latch_wr, .latch_din,
        .rom_addr (z80_rom_addr), .rom_cs(z80_rom_cs), .rom_data(z80_rom_data), .rom_ok(z80_rom_ok),
        .oki_wrn  (z_oki_wrn), .oki_din(z_oki_din), .oki_dout(oki_dout),
        .fm_left, .fm_right,
        .dbg_io_wr(dbg_z80_io_wr), .dbg_io_addr(dbg_z80_io_addr), .dbg_io_data(dbg_z80_io_data)
    );
    assign dbg_latch_wr = latch_wr;

    // ------------------------------------------------------------------
    // Mixers: Shanghai III levels measured against the PCB (shangha3_mixer.sv);
    // heberpop/blocken FM + OKI (ga9201_mixer.sv)
    // ------------------------------------------------------------------
    logic signed [15:0] snd_s3, snd_z80;
    shangha3_mixer u_mix (
        .clk     (clk),
        .reset   (reset),
        .ce_psg  (ce_psg),
        .mute    (snd_pause),
        .balance (snd_balance),
        .psg_snd (psg_snd),
        .oki_snd (oki_snd),
        .snd     (snd_s3)
    );
    ga9201_mixer u_mix2 (
        .clk     (clk),
        .reset   (reset),
        .mute    (snd_pause),
        .balance (snd_balance),
        .fm_left, .fm_right,
        .oki_snd (oki_snd),
        .snd     (snd_z80)
    );
    always_ff @(posedge clk) snd <= g_s3 ? snd_s3 : snd_z80;

    // ------------------------------------------------------------------
    // CPU read data + DTACK
    // ------------------------------------------------------------------
    logic [3:0] wait_cnt;
    logic       ready;
    wire        blit_wr_conflict = blit_busy && !cpu_rw &&
                                   ({4'b0, ram_a} >= blit_scan_from ||
                                    ({1'b0, ram_a} >= {1'b0, blit_tm_from} && ram_a < 15'h2000));

    // work RAM write: once per bus cycle, as soon as there is no conflict
    logic ram_wr_done;
    always_ff @(posedge clk) begin
        if (reset || !cpu_cyc) ram_wr_done <= 1'b0;
        else if (ram_we)       ram_wr_done <= 1'b1;
    end
    assign ram_we = cpu_cyc && sel_ram && !cpu_rw && !ram_wr_done && !blit_wr_conflict;

    // ------------------------------------------------------------------
    // Blitter bus hold (v0.1.10), a calibrated model of the real chip's speed.
    // How the game paces itself (68000 code): the vblank IRQ starts the
    // blitter only if the main loop has finished its update and is waiting;
    // early in each update the main loop also waits for vblank (10A42). On
    // the PCB the title, mode select and zodiac screens run at 30 updates per
    // second and gameplay and the demo at 60 (Aaron's videos; the mode-select
    // timeout takes 14.9 s on the PCB and 7.4 s in MAME). That fits the CPU
    // being stopped for a while after vblank while the real, much slower chip
    // draws, applied from the end of vblank (the game checks for vblank early
    // in each update, so the CPU must get through vblank first).
    // ------------------------------------------------------------------
    // Hold per destination pixel the blitter processes (transparent ones
    // included), in 1/16 clock: 110 = 6.875 clocks = 72 ns, i.e. ~14 Mpixel/s.
    // From the measurements the window is about 5.9 to 7.9 clocks per pixel
    // (mode select must miss the frame, the busiest demo screen must not).
    localparam int HOLD_PER_PX_X16 = 110;
    logic        bus_hold;
    logic [27:0] hold_acc;                         // pending hold, in 1/16 clock
    always_ff @(posedge clk) begin
        if (reset) begin
            hold_acc <= '0;
            bus_hold <= 1'b0;
        end else begin
            hold_acc <= hold_acc + (blit_px_step ? 28'(HOLD_PER_PX_X16) : 28'd0)
                                 - ((bus_hold && hold_acc >= 28'd16) ? 28'd16 : 28'd0);
            // Shanghai III only: the model is calibrated on its PCB. On
            // heberpop the same model halves the attract mode's speed against
            // MAME (its screens are full of large sprites); without a PCB to
            // check, those games run like MAME (no hold).
            bus_hold <= g_s3 && !vblank && (hold_acc >= 28'd16);
            if (ss_apply) {bus_hold, hold_acc} <= ss_hdr6[28:0];
        end
    end

    always_comb begin
        if (ss_ovr)                  ready = wait_cnt >= 4'd2;   // save-state handler / vectors
        else if (bus_hold && !cpu_iack) ready = 1'b0;   // CPU off the bus while the blitter "draws"
        else if (sel_rom || sel_grom) ready = prog_ok && wait_cnt >= 4'd2;
        // MAME's blitter is instantaneous. Ours first snapshots the command
        // list (and tilemap RAM if used) in ~1% of a frame, then draws from
        // the snapshot. Only CPU writes to words not yet snapshotted wait.
        // Real PCB arbitration is unknown; the real board runs the attract
        // mode smoothly, so the real chip can't hold the CPU up for long.
        else if (sel_ram)            ready = wait_cnt >= 4'd2 && !blit_wr_conflict;
        else if (sel_pal)            ready = wait_cnt >= 4'd2;
        else                         ready = wait_cnt >= 4'd4;   // I/O: give jt49 time
    end

    always_ff @(posedge clk) begin
        if (reset || !cpu_as_cyc) wait_cnt <= '0;
        else if (wait_cnt != 4'hf) wait_cnt <= wait_cnt + 4'd1;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            cpu_din     <= 16'hffff;
            cpu_dtack_n <= 1'b1;
            cpu_vpa_n   <= 1'b1;
        end else begin
            cpu_vpa_n   <= !cpu_iack;                 // autovectored interrupts
            cpu_dtack_n <= !(cpu_as_cyc && ready);

            if      (ss_ovr)              cpu_din <= ss_dout;
            else if (sel_rom || sel_grom) cpu_din <= prog_data;
            else if (sel_ram) cpu_din <= ram_q;
            else if (sel_pal) cpu_din <= pal_q;
            else if (sel_io && g_s3) begin
                case (io_reg)
                    IO_INPUTS: cpu_din <= {2'b11, in_inputs[13:8], 2'b11, in_inputs[5:0]};
                    IO_SYSTEM: cpu_din <= {8'hff, !vblank, in_system};
                    IO_AY_RD:  cpu_din <= {8'hff, ay_dout};
                    IO_PROT:   cpu_din <= {12'h000, prot_q};
                    IO_OKI:    cpu_din <= {8'hff, oki_dout};
                    default:   cpu_din <= 16'hffff;
                endcase
            end
            else if (sel_io) begin
                // heberpop/blocken: vblank on INPUTS bits 7 and 15 ("has to toggle");
                // button 3 (bits 6/14) only on blocken
                case (io_reg)
                    IO_INPUTS: cpu_din <= {!vblank, g_blk ? in_inputs[14] : 1'b1, in_inputs[13:8],
                                           !vblank, g_blk ? in_inputs[6]  : 1'b1, in_inputs[5:0]};
                    IO_SYSTEM: cpu_din <= {8'hff, 1'b1, in_system};
                    IO_DSW:    cpu_din <= {dsw2, dsw1};
                    default:   cpu_din <= 16'hffff;
                endcase
            end
            else cpu_din <= 16'hffff;                     // unmapped
        end
    end

    // ------------------------------------------------------------------
    // Debug taps
    // ------------------------------------------------------------------
    assign dbg_cpu_addr      = cpu_addr;
    assign dbg_cpu_cyc_start = cyc_start;
    assign dbg_cpu_rw        = cpu_rw;
    assign dbg_cpu_dout      = cpu_dout;
    assign dbg_cpu_din       = cpu_din;
    assign dbg_cpu_dtack     = !cpu_dtack_n;
    assign dbg_blit_busy     = blit_busy;
    assign dbg_ram_stall     = cpu_cyc && sel_ram && blit_wr_conflict;

    // ------------------------------------------------------------------
    // Save states
    //
    // The 68000's registers are saved without touching fx68k: with the rest
    // of the board stopped at a clean point (blitter, vblank copy and bus-hold
    // model idle), the CPU takes a level-7 interrupt whose vector points at a
    // small handler served from FF0000-FF001F. It pushes D0-D7/A0-A6 and USP
    // onto the supervisor stack (work RAM) and writes SSP to FF0000, where it
    // is latched. From then on the CPU is held in reset and the whole machine
    // state is: work RAM, palette, ss_ssp, the video position and a few
    // registers, all readable as 32-bit "state words" (ss_rd / ss_idx).
    // Not saved, measured in simulation (SAVESTATE_PLAN.md): the draw buffer
    // (redrawn within 1-3 frames), blitter snapshots, display path, memory
    // controllers and caches (they hold ROM copies only).
    //
    // Leaving (after a save has been read out, or after a load): the CPU is
    // reset alone, its reset-vector reads return SSP = ss_ssp and PC = FF0010,
    // where the second half of the handler pops the registers and executes
    // RTE. A save and a load therefore leave the same way. Before that, a load
    // runs the pixel clock until the video position equals the saved one, so
    // the vblank IRQ and the copy come at the same point as before the save.
    //
    // Same idea as the Taito F2 MiSTer core (wickerwaka); written fresh here.
    //
    // State words (32 bits; ss_idx):
    //   0000      'GA92'                     0001  version, game id
    //   0002      SSP                        0003  vcnt, hcnt, pix_div
    //   0004      irq4, flip, gfxlist, coin  0005  oki data, latch, protection
    //   0006      bus hold model             0007  reserved
    //   0400-07FF palette (2 words each)     4000-7FFF work RAM (2 words each)
    //   everything else reads 0 (room for the sound section)
    // ------------------------------------------------------------------
    localparam logic [31:0] SS_MAGIC   = 32'h47413932;            // "GA92"
    localparam logic [15:0] SS_VERSION = 16'd1;
`ifdef SS_SIM_GUARD
    localparam int          SS_MIN_FRAMES = `SS_SIM_GUARD;        // simulation only: shorter runs
`else
    localparam int          SS_MIN_FRAMES = 960;                  // ~17 s: past every game's boot RAM test
`endif

    typedef enum logic [3:0] {
        SS_IDLE,   // running
        SS_WAIT,   // save: wait for blitter / copy / bus hold idle (game still running)
        SS_IRQ,    // save: IPL7 until acknowledged
        SS_RUN,    // save: handler pushes the registers
        SS_LWAIT,  // load: 68000 held; wait for blitter / copy idle; state words may arrive
        SS_HOLD,   // 68000 held, board frozen: state words read / written
        SS_SEEK,   // load: pixel clock runs until the saved video position
        SS_SETTLE, // load: wait for the vblank copy / blitter to finish
        SS_APPLY,  // load: registers from the header
        SS_RST,    // 68000 reset with injected vectors
        SS_RRUN    // 68000 pops its registers and returns
    } ss_t;
    ss_t         ss_st;
    logic        ss_is_load, ss_commit_pend;
    logic [31:0] ss_ssp;
    logic [6:0]  ss_cnt;
    logic        ss_seen;              // handler code fetched
    logic [9:0]  ss_frames;            // frames since reset (saturating)
    logic [31:0] ss_hdr [0:7];         // header words of a load
    wire  ss_region = cpu_addr[23:5] == 19'h7F800;            // FF0000-FF001F
    function automatic logic [15:0] ss_code(input logic [3:0] w);
        case (w)
            4'h0: ss_code = 16'h48E7; 4'h1: ss_code = 16'hFFFE;     // movem.l d0-d7/a0-a6,-(a7)
            4'h2: ss_code = 16'h4E6E;                               // move.l usp,a6
            4'h3: ss_code = 16'h2F0E;                               // move.l a6,-(a7)
            4'h4: ss_code = 16'h4DF9; 4'h5: ss_code = 16'h00FF;     // lea $ff0000,a6
            4'h6: ss_code = 16'h0000;
            4'h7: ss_code = 16'h2C8F;                               // move.l a7,(a6)   <- SSP out
            4'h8: ss_code = 16'h2C5F;                               // movea.l (a7)+,a6 <- restore entry FF0010
            4'h9: ss_code = 16'h4E66;                               // move.l a6,usp
            4'hA: ss_code = 16'h4CDF; 4'hB: ss_code = 16'h7FFF;     // movem.l (a7)+,d0-d7/a0-a6
            4'hC: ss_code = 16'h4E73;                               // rte
            default: ss_code = 16'h4E71;                            // nop
        endcase
    endfunction

    wire [21:0] ss_pos      = {vcnt, hcnt, pix_div};
    wire        ss_pos_hit  = ss_pos == ss_hdr[3][21:0];
    wire        ss_hdr_ok   = ss_hdr[0] == SS_MAGIC && ss_hdr[1] == {SS_VERSION, 14'd0, game_id} &&
                              ss_hdr[3][21:13] < 9'd262 && ss_hdr[3][3:0] < 4'd12;
    assign ss_hdr4 = ss_hdr[4];
    assign ss_hdr5 = ss_hdr[5];
    assign ss_hdr6 = ss_hdr[6];

    always_comb begin
        ss_snd_stop  = ss_st != SS_IDLE && ss_st != SS_WAIT;
        ss_pix_stop  = ss_st != SS_IDLE && ss_st != SS_WAIT && !(ss_st == SS_SEEK && !ss_pos_hit);
        ss_cpu_clk   = ss_st != SS_IDLE && ss_st != SS_WAIT;
        ss_irq7      = ss_st == SS_IRQ;
        ss_cpu_reset = ss_st == SS_LWAIT || ss_st == SS_HOLD || ss_st == SS_SEEK ||
                       ss_st == SS_SETTLE || ss_st == SS_APPLY || ss_st == SS_RST;
        ss_apply     = ss_st == SS_APPLY && ss_hdr_ok;
        ss_ovr  = 1'b0;
        ss_dout = 16'hffff;
        if (ss_st == SS_RUN || ss_st == SS_RRUN || ss_st == SS_IRQ) begin
            if (ss_region && cpu_rw) begin
                ss_ovr = 1'b1; ss_dout = ss_code(cpu_addr[4:1]);
            end else if (ss_st != SS_RRUN && cpu_rw && cpu_addr[23:2] == 22'h1F) begin   // 00007C/E: level-7 autovector
                ss_ovr = 1'b1; ss_dout = cpu_addr[1] ? 16'h0000 : 16'h00FF;
            end else if (ss_st == SS_RRUN && !ss_seen && cpu_rw && cpu_addr[23:3] == 21'h0) begin   // reset vectors
                ss_ovr = 1'b1;
                case (cpu_addr[2:1])
                    2'd0: ss_dout = ss_ssp[31:16];
                    2'd1: ss_dout = ss_ssp[15:0];
                    2'd2: ss_dout = 16'h00FF;
                    default: ss_dout = 16'h0010;
                endcase
            end else if (ss_region && !cpu_rw) begin
                ss_ovr = 1'b1;
            end
        end
    end
    assign ss_active = ss_st != SS_IDLE;
    assign ss_ready  = ss_st == SS_HOLD && !ss_is_load;

    // header words as they are now (save)
    function automatic logic [31:0] ss_hdr_now(input logic [2:0] i);
        case (i)
            3'd0: ss_hdr_now = SS_MAGIC;
            3'd1: ss_hdr_now = {SS_VERSION, 14'd0, game_id};
            3'd2: ss_hdr_now = ss_ssp;
            3'd3: ss_hdr_now = {10'd0, ss_pos};
            3'd4: ss_hdr_now = {6'd0, irq4, dbg_flip, dbg_gfxlist, dbg_coinctrl};
            3'd5: ss_hdr_now = {8'd0, dbg_oki_data, latch_din, prot_cnt, prot_q};
            3'd6: ss_hdr_now = {3'd0, bus_hold, hold_acc};
            default: ss_hdr_now = 32'd0;
        endcase
    endfunction

    // state word access (only while the 68000 is held: LWAIT / HOLD)
    logic        m_busy, m_wr;
    logic [2:0]  m_step;
    logic [14:0] m_idx;
    logic [31:0] m_wd;
    wire         m_hdr = m_idx[14:3] == 12'd0;
    wire         m_pal = m_idx[14:10] == 5'b00001;
    wire         m_ram = m_idx[14];
    wire         ss_held = ss_st == SS_LWAIT || ss_st == SS_HOLD;

    always_ff @(posedge clk) begin
        ss_ack     <= 1'b0;
        ss_mwe_ram <= 1'b0;
        ss_mwe_pal <= 1'b0;
        if (reset) begin
            m_busy <= 1'b0;
            ss_mem <= 1'b0;
        end else begin
            ss_mem <= ss_held;
            if (!m_busy) begin
                if ((ss_rd || ss_wr) && ss_held) begin
                    m_busy <= 1'b1;
                    m_wr   <= ss_wr;
                    m_idx  <= ss_idx;
                    m_wd   <= ss_wdata;
                    m_step <= '0;
                end else if (ss_rd || ss_wr) begin
                    ss_rdata <= 32'd0;          // not held: nothing to access
                    ss_ack   <= 1'b1;
                end
            end else begin
                m_step <= m_step + 3'd1;
                if (m_hdr || !(m_pal || m_ram)) begin
                    // header / unused words: one clock
                    if (m_wr) begin
                        if (m_hdr) ss_hdr[m_idx[2:0]] <= m_wd;
                    end else begin
                        ss_rdata <= m_hdr ? ss_hdr_now(m_idx[2:0]) : 32'd0;
                    end
                    ss_ack <= 1'b1;
                    m_busy <= 1'b0;
                end else if (m_wr) begin
                    // RAM / palette write: two 16-bit words
                    ss_maddr <= m_ram ? {1'b0, m_idx[13:0], m_step[0]} : {5'd0, m_idx[9:0], m_step[0]};
                    ss_mwd   <= m_step[0] ? m_wd[15:0] : m_wd[31:16];
                    ss_mwe_ram <= m_ram;
                    ss_mwe_pal <= m_pal;
                    if (m_step == 3'd1) begin
                        ss_ack <= 1'b1;
                        m_busy <= 1'b0;
                    end
                end else begin
                    // RAM / palette read: address, RAM samples it, data out (x2)
                    case (m_step)
                        3'd0: ss_maddr <= m_ram ? {1'b0, m_idx[13:0], 1'b0} : {5'd0, m_idx[9:0], 1'b0};
                        3'd2: begin
                            ss_rdata[31:16] <= m_ram ? ram_q : pal_q;
                            ss_maddr <= m_ram ? {1'b0, m_idx[13:0], 1'b1} : {5'd0, m_idx[9:0], 1'b1};
                        end
                        3'd4: begin
                            ss_rdata[15:0] <= m_ram ? ram_q : pal_q;
                            ss_ack <= 1'b1;
                            m_busy <= 1'b0;
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        ss_done      <= 1'b0;
        ss_err       <= 1'b0;
        ss_reset_req <= 1'b0;
        if (reset) begin
            ss_st     <= SS_IDLE;
            ss_frames <= '0;
            ss_is_load     <= 1'b0;
            ss_commit_pend <= 1'b0;
        end else begin
            if (vblank_start && ss_frames != 10'h3FF) ss_frames <= ss_frames + 10'd1;
            if (ss_commit) ss_commit_pend <= 1'b1;
            case (ss_st)
                SS_IDLE: begin
                    ss_commit_pend <= 1'b0;
                    if (ss_load) begin
                        ss_st <= SS_LWAIT; ss_is_load <= 1'b1;
                    end else if (ss_save) begin
                        if (ss_frames >= 10'(SS_MIN_FRAMES)) begin ss_st <= SS_WAIT; ss_is_load <= 1'b0; end
                        else ss_err <= 1'b1;
                    end
                end
                SS_WAIT: begin
                    if (ss_load) begin
                        ss_st <= SS_LWAIT; ss_is_load <= 1'b1;
                    end else if (!blit_busy && !fb_copying && !bus_hold && (!g_s3 || hold_acc < 28'd16))
                        ss_st <= SS_IRQ;
                end
                SS_IRQ:  if (cpu_iack && cpu_addr[3:1] == 3'b111) ss_st <= SS_RUN;
                SS_RUN: begin
                    if (cyc_start && ss_region && !cpu_rw && cpu_addr[1] == 1'b0) ss_ssp[31:16] <= cpu_dout;
                    if (cyc_start && ss_region && !cpu_rw && cpu_addr[1] == 1'b1) begin
                        ss_ssp[15:0] <= cpu_dout;
                        ss_st <= SS_HOLD;            // everything is in RAM now
                    end
                end
                SS_LWAIT: if (!blit_busy && !fb_copying) ss_st <= SS_HOLD;
                SS_HOLD: begin
                    if (!ss_is_load && ss_release) begin
                        ss_st <= SS_RST; ss_cnt <= '0;
                    end else if (ss_is_load && (ss_commit || ss_commit_pend) && !m_busy) begin
                        ss_commit_pend <= 1'b0;
                        if (ss_hdr_ok) begin
                            ss_ssp <= ss_hdr[2];
                            ss_st  <= SS_SEEK;
                        end else begin
                            ss_err       <= 1'b1;   // not a state of this game/version
                            ss_reset_req <= 1'b1;   // RAM is already overwritten: start over
                            ss_st        <= SS_IDLE;
                        end
                    end
                end
                SS_SEEK:   if (ss_pos_hit) ss_st <= SS_SETTLE;
                SS_SETTLE: if (!blit_busy && !fb_copying) ss_st <= SS_APPLY;
                SS_APPLY:  begin ss_st <= SS_RST; ss_cnt <= '0; end
                SS_RST: begin
                    ss_cnt <= ss_cnt + 7'd1;
                    if (&ss_cnt) begin ss_st <= SS_RRUN; ss_seen <= 1'b0; end
                end
                SS_RRUN: begin
                    if (cyc_start && ss_region && cpu_rw) ss_seen <= 1'b1;
                    if (cyc_start && ss_seen && !ss_region && cpu_rw && cpu_fc[1:0] == 2'b10) begin
                        ss_st   <= SS_IDLE;
                        ss_done <= ss_is_load;
                        if (ss_is_load) ss_frames <= 10'h3FF;   // a loaded game is past its boot test
                    end
                end
                default: ss_st <= SS_IDLE;
            endcase
        end
    end

endmodule

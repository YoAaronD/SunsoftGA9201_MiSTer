// Simulation top for the Pocket port: the shared game core (shangha3_top) with
// the Pocket's ROM loader (APF bridge writes) and the cellular-RAM frame
// buffer (pocket_fb + two chip models) in place of the MiSTer's hps_io and
// DDR3. Driven by pocket/sim/pocket_tb.cpp.

module pocket_sim_top (
    input  logic        clk,            // 96 MHz
    input  logic        clk_74a,
    input  logic        sys_init,       // PLL not locked
    input  logic        reset,          // game reset (APF reset_n low)
    input  logic        running,        // APF reset_n
    input  logic        pause,
    input  logic [1:0]  game_id,
    input  logic        direct_scan,

    input  logic        bridge_wr,
    input  logic [31:0] bridge_addr,
    input  logic [31:0] bridge_wr_data,
    input  logic        bridge_rd,
    output logic [31:0] ss_bridge_rd_data,     // save-state window (0x4xxxxxxx)
    input  logic        savestate_start,
    output logic        savestate_start_ack, savestate_start_busy, savestate_start_ok, savestate_start_err,
    input  logic        savestate_load,
    output logic        savestate_load_ack, savestate_load_busy, savestate_load_ok, savestate_load_err,
    output logic        ss_active,
    output int          dbg_ss_st, dbg_rd_cnt, dbg_reading, dbg_r_idx, dbg_r_on, dbg_rf_empty, dbg_ready,

    input  logic [15:0] in_inputs,
    input  logic [6:0]  in_system,
    input  logic [7:0]  dsw1,
    input  logic [7:0]  dsw2,

    output logic        ce_pix,
    output logic        hsync, vsync, hblank, vblank,
    output logic [7:0]  red, green, blue,
    output logic signed [15:0] snd,

    output logic        ioctl_download,
    output logic        load_overflow,
    output logic        fb_ready,
    output int          cram_errors,
    output int          cram_words_w,
    output int          cram_words_r,
    output logic        bcr_ok,
    output int          copies,         // vblank copies seen
    output int          copy_min,       // shortest / longest draw-buffer read (clocks)
    output int          copy_max,

    output logic        SDRAM_CLK,
    output logic        SDRAM_CKE,
    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    input  logic [15:0] SDRAM_DQ_IN,
    output logic [15:0] SDRAM_DQ_OUT,
    output logic        SDRAM_DQ_OE,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nWE
);
    logic        ioctl_wr, ioctl_wait;
    logic [26:0] ioctl_addr;
    logic [7:0]  ioctl_dout;

    pocket_loader u_loader (
        .clk_74a, .bridge_wr, .bridge_addr, .bridge_wr_data, .running,
        .clk, .reset(sys_init),
        .ioctl_download, .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
        .overflow(load_overflow)
    );

    logic        ddr_busy, ddr_dout_ready, ddr_rd, ddr_we;
    logic [7:0]  ddr_burstcnt, ddr_be;
    logic [28:0] ddr_addr;
    logic [63:0] ddr_dout, ddr_din;

    logic        ss_save, ss_load, ss_commit, ss_release, ss_ready, ss_done, ss_err;
    logic        ss_rd, ss_wr, ss_ack;
    logic [14:0] ss_idx;
    logic [31:0] ss_wdata, ss_rdata;
    pocket_ss_bridge u_ss (
        .clk_74a, .bridge_addr, .bridge_rd, .bridge_wr, .bridge_wr_data, .rd_data(ss_bridge_rd_data),
        .savestate_start, .savestate_start_ack, .savestate_start_busy, .savestate_start_ok, .savestate_start_err,
        .savestate_load, .savestate_load_ack, .savestate_load_busy, .savestate_load_ok, .savestate_load_err,
        .clk, .reset(sys_init),
        .ss_save, .ss_load, .ss_commit, .ss_release, .ss_ready, .ss_done, .ss_err, .ss_active,
        .ss_rd, .ss_wr, .ss_idx, .ss_wdata, .ss_rdata, .ss_ack
    );

    assign dbg_ss_st    = int'(u_core.u_board.ss_st);
    assign dbg_rd_cnt   = int'(u_ss.rd_cnt);
    assign dbg_reading  = int'(u_ss.reading);
    assign dbg_r_idx    = int'(u_ss.r_idx);
    assign dbg_r_on     = int'(u_ss.r_on);
    assign dbg_rf_empty = int'(u_ss.rf_empty);
    assign dbg_ready    = int'(ss_ready);

    shangha3_top u_core (
        .clk, .reset, .sdram_init(sys_init), .pause, .snd_balance(3'd0), .game_id, .direct_scan,
        .ss_save, .ss_load, .ss_commit, .ss_release, .ss_ready, .ss_done, .ss_err, .ss_active,
        .ss_rd, .ss_wr, .ss_idx, .ss_wdata, .ss_rdata, .ss_ack,
        .ioctl_download, .ioctl_index(16'd0), .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
        .in_inputs, .in_system, .dsw1, .dsw2,
        .ce_pix, .hsync, .vsync, .hblank, .vblank, .vblank_next(), .red, .green, .blue,
        .ddr_busy, .ddr_burstcnt, .ddr_addr, .ddr_dout, .ddr_dout_ready, .ddr_rd, .ddr_din,
        .ddr_be, .ddr_we,
        .rot_we(1'b0), .rot_addr(29'd0), .rot_din(64'd0), .rot_be(8'd0),
        .snd,
        .SDRAM_CLK, .SDRAM_CKE, .SDRAM_A, .SDRAM_BA, .SDRAM_DQ_IN, .SDRAM_DQ_OUT, .SDRAM_DQ_OE,
        .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_nCS, .SDRAM_nCAS, .SDRAM_nRAS, .SDRAM_nWE
    );

    // frame buffer + two chip models
    logic        c0_clk, c1_clk, c0_oe, c1_oe, c0_wait, c1_wait;
    logic [21:16] c0_a, c1_a;
    logic [15:0] c0_o, c1_o, c0_i, c1_i;
    logic        c0_adv, c0_cre, c0_ce, c0_oen, c0_we;
    logic        c1_adv, c1_cre, c1_ce, c1_oen, c1_we;

    pocket_fb u_fb (
        .clk, .reset(sys_init), .ready(fb_ready),
        .ddr_busy, .ddr_burstcnt, .ddr_addr, .ddr_dout, .ddr_dout_ready, .ddr_rd, .ddr_din,
        .ddr_be, .ddr_we,
        .c0_clk, .c0_a, .c0_dq_o(c0_o), .c0_dq_oe(c0_oe), .c0_dq_i(c0_i), .c0_wait,
        .c0_adv_n(c0_adv), .c0_cre, .c0_ce_n(c0_ce), .c0_oe_n(c0_oen), .c0_we_n(c0_we),
        .c1_clk, .c1_a, .c1_dq_o(c1_o), .c1_dq_oe(c1_oe), .c1_dq_i(c1_i), .c1_wait,
        .c1_adv_n(c1_adv), .c1_cre, .c1_ce_n(c1_ce), .c1_oe_n(c1_oen), .c1_we_n(c1_we)
    );

    int e0, e1, w0, w1, r0, r1;
    logic ok0, ok1;
    cram_model #(.SEED(11)) u_m0 (
        .clk(c0_clk), .a(c0_a), .dq_i(c0_o), .dq_oe(c0_oe), .dq_o(c0_i), .wait_o(c0_wait),
        .adv_n(c0_adv), .cre(c0_cre), .ce_n(c0_ce), .oe_n(c0_oen), .we_n(c0_we),
        .errors(e0), .words_w(w0), .words_r(r0), .bcr_ok(ok0)
    );
    cram_model #(.SEED(29)) u_m1 (
        .clk(c1_clk), .a(c1_a), .dq_i(c1_o), .dq_oe(c1_oe), .dq_o(c1_i), .wait_o(c1_wait),
        .adv_n(c1_adv), .cre(c1_cre), .ce_n(c1_ce), .oe_n(c1_oen), .we_n(c1_we),
        .errors(e1), .words_w(w1), .words_r(r1), .bcr_ok(ok1)
    );
    assign cram_errors  = e0 + e1;
    assign cram_words_w = w0 + w1;
    assign cram_words_r = r0 + r1;
    assign bcr_ok       = ok0 && ok1;

    // how long each vblank copy holds the blitter (must be 86016 clocks, as on
    // the MiSTer, if the frame buffer keeps up)
    int   clen;
    logic rb_q;
    wire  rb = u_core.u_board.u_video.rd_busy;
    initial begin copies = 0; copy_min = 1 << 30; copy_max = 0; clen = 0; end
    always_ff @(posedge clk) begin
        rb_q <= rb;
        if (rb) clen <= clen + 1;
        else if (rb_q) begin
            copies <= copies + 1;
            if (clen < copy_min) copy_min <= clen;
            if (clen > copy_max) copy_max <= clen;
            clen <= 0;
        end
    end
endmodule

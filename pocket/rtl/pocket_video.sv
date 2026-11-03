// Core video (96 MHz with an 8 MHz pixel enable) -> Analogue Pocket scaler.
//
// The Pocket wants one pixel per video_rgb_clock cycle. The PLL makes an
// 8 MHz clock (and its 90-degree copy) from the same VCO as the 96 MHz core
// clock, so the two are related: each pixel value is stable for 12 core
// clocks and the 8 MHz domain samples it exactly once. The timing analyser
// checks the crossing like any synchronous path (10.4 ns).
//
// APF rules (as used by other Pocket cores): video_vs and video_hs are
// one-clock pulses at the start of sync, video_de marks the 384 x 224 active
// pixels, and video_rgb is 0 outside DE (scaler slot 0).
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).

module pocket_video (
    input  logic        clk_pix,        // 8 MHz from the core PLL
    input  logic [7:0]  red, green, blue,
    input  logic        hblank, vblank, hsync, vsync,

    output logic [23:0] video_rgb,
    output logic        video_de,
    output logic        video_skip,
    output logic        video_vs,
    output logic        video_hs
);
    logic [7:0] r_s, g_s, b_s;
    logic       hb_s, vb_s, hs_s, vs_s, hs_l, vs_l;

    always_ff @(posedge clk_pix) begin
        // sample the core's registers (one value per pixel)
        {r_s, g_s, b_s}        <= {red, green, blue};
        {hb_s, vb_s, hs_s, vs_s} <= {hblank, vblank, hsync, vsync};
        hs_l <= hs_s;
        vs_l <= vs_s;

        video_vs   <= vs_s && !vs_l;
        video_hs   <= hs_s && !hs_l;
        video_de   <= !hb_s && !vb_s;
        video_skip <= 1'b0;
        video_rgb  <= (!hb_s && !vb_s) ? {r_s, g_s, b_s} : 24'd0;
    end
endmodule

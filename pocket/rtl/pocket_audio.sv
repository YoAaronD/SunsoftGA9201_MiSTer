// Mono 16-bit core audio -> Analogue Pocket I2S (48 kHz, 16 of 32 bits per
// channel, MSB first), all in the clk_74a domain.
//
// MCLK = 12.288 MHz from a fractional accumulator, SCLK = MCLK / 4, LRCK =
// SCLK / 64, data changes on the falling SCLK edge. The bit timing follows
// the Analogue core template and Adam Gastineau's sound_i2s.sv (MIT).
//
// Crossing from the core clock: the core register is copied into a holding
// register together with a toggle; clk_74a takes the holding register a few
// cycles after it sees the toggle change, when it is long stable.
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).

module pocket_audio (
    input  logic               clk,          // core clock
    input  logic signed [15:0] snd,
    input  logic               clk_74a,
    output logic               audio_mclk,
    output logic               audio_lrck,
    output logic               audio_dac
);
    // ------------------------------------------------------------------
    // core clock: hand a sample over at 48 kHz (every 2000 clocks at 96 MHz)
    // ------------------------------------------------------------------
    logic [10:0] div;
    logic [15:0] hold;
    logic        tgl;
    always_ff @(posedge clk) begin
        div <= (div == 11'd1999) ? 11'd0 : div + 11'd1;
        if (div == 11'd0) begin
            hold <= snd;
            tgl  <= ~tgl;
        end
    end

    // ------------------------------------------------------------------
    // clk_74a
    // ------------------------------------------------------------------
    logic [3:0]  tgl_s;
    logic [15:0] smp;
    always_ff @(posedge clk_74a) begin
        tgl_s <= {tgl_s[2:0], tgl};
        if (tgl_s[3] != tgl_s[2]) smp <= hold;      // hold has been stable for 2+ cycles
    end

    // MCLK = 74.25 MHz x 245760 / 742500 / 2 = 12.288 MHz
    logic [21:0] acc;
    always_ff @(posedge clk_74a) begin
        if (acc >= 22'd742500 - 22'd245760) begin
            acc        <= acc + 22'd245760 - 22'd742500;
            audio_mclk <= ~audio_mclk;
        end else begin
            acc <= acc + 22'd245760;
        end
    end

    logic       mclk_l;
    logic [1:0] mdiv;
    wire        sclk = mdiv[1];
    logic       sclk_l;
    logic [4:0] lr_cnt;
    logic [31:0] shift;
    always_ff @(posedge clk_74a) begin
        mclk_l <= audio_mclk;
        if (audio_mclk && !mclk_l) mdiv <= mdiv + 2'd1;
        sclk_l <= sclk;
        if (sclk_l && !sclk) begin               // falling SCLK edge
            audio_dac <= shift[31];
            lr_cnt    <= lr_cnt + 5'd1;
            if (lr_cnt == 5'd31) begin
                audio_lrck <= ~audio_lrck;
                if (!audio_lrck) shift <= {smp, smp};    // same sample left and right
            end else if (lr_cnt < 5'd16) begin
                shift <= {shift[30:0], 1'b0};
            end
        end
    end
endmodule

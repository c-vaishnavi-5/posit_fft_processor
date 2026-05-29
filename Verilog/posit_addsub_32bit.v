module posit_addsub_32bit (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        op,
    output reg  [31:0] p,
    output reg         valid_out
);

localparam [31:0] POSIT_ZERO   = 32'h00000000;
localparam [31:0] POSIT_NAR    = 32'h80000000;
localparam [31:0] POSIT_MAXPOS = 32'h7FFFFFFF;
localparam [31:0] POSIT_MINNEG = 32'h80000001;
localparam        ES           = 3;
localparam        MAX_K        = 4;
localparam        MIN_K        = -5;

// ════════════════════════════════════════════════════════════
//  STAGE 1 — data_extract
// ════════════════════════════════════════════════════════════

wire zero_a_c = (a == POSIT_ZERO);
wire zero_b_c = (b == POSIT_ZERO);
wire nar_a_c  = (a == POSIT_NAR);
wire nar_b_c  = (b == POSIT_NAR);

wire [31:0] b_eff_c      = op ? (~b + 1'b1) : b;
wire        sign_b_eff_c = op ? ~b[31] : b[31];
wire [31:0] mag_a_c      = a[31] ? (~a + 1'b1) : a;
wire [31:0] mag_b_c      = b[31] ? (~b + 1'b1) : b;

wire        s1_valid;
wire signed [31:0] k_a_w, k_b_w;
wire [2:0]  exp_a_w, exp_b_w;
wire [26:0] frac_a_w, frac_b_w;

data_extract_5bit_regime ext_a (
    .clk(clk), .rst_n(~rst), .valid_in(valid_in),
    .flp_a(mag_a_c), .valid_out(s1_valid),
    .ra_o(k_a_w), .exp_a(exp_a_w), .fract_a(frac_a_w)
);
data_extract_5bit_regime ext_b (
    .clk(clk), .rst_n(~rst), .valid_in(valid_in),
    .flp_a(mag_b_c), .valid_out(),
    .ra_o(k_b_w), .exp_a(exp_b_w), .fract_a(frac_b_w)
);

reg        s1_zero_a, s1_zero_b, s1_nar_a, s1_nar_b;
reg        s1_sign_a, s1_sign_b_eff;
reg [31:0] s1_a_raw, s1_b_eff;

always @(posedge clk) begin
    if (rst) begin
        s1_zero_a     <= 0; s1_zero_b     <= 0;
        s1_nar_a      <= 0; s1_nar_b      <= 0;
        s1_sign_a     <= 0; s1_sign_b_eff <= 0;
        s1_a_raw      <= 0; s1_b_eff      <= 0;
    end else begin
        s1_zero_a     <= zero_a_c;
        s1_zero_b     <= zero_b_c;
        s1_nar_a      <= nar_a_c;
        s1_nar_b      <= nar_b_c;
        s1_sign_a     <= a[31];
        s1_sign_b_eff <= sign_b_eff_c;
        s1_a_raw      <= a;
        s1_b_eff      <= b_eff_c;
    end
end

// ════════════════════════════════════════════════════════════
//  STAGE 2 — scale computation
// ════════════════════════════════════════════════════════════

wire signed [31:0] scale_a_c = (k_a_w <<< 3) + {29'b0, exp_a_w};
wire signed [31:0] scale_b_c = (k_b_w <<< 3) + {29'b0, exp_b_w};

wire a_larger_c = (scale_a_c >= scale_b_c);
wire signed [31:0] scale_diff_c = a_larger_c ?
    (scale_a_c - scale_b_c) : (scale_b_c - scale_a_c);

reg        s2_valid;
reg        s2_zero_a, s2_zero_b, s2_nar_a, s2_nar_b;
reg        s2_sign_a, s2_sign_b_eff, s2_a_larger;
reg [31:0] s2_a_raw, s2_b_eff;
reg signed [31:0] s2_scale_diff;
reg signed [31:0] s2_k_a, s2_k_b;
reg [2:0]  s2_exp_a, s2_exp_b;
reg [26:0] s2_frac_a, s2_frac_b;

always @(posedge clk) begin
    if (rst) begin
        s2_valid      <= 0;
        s2_zero_a     <= 0; s2_zero_b     <= 0;
        s2_nar_a      <= 0; s2_nar_b      <= 0;
        s2_sign_a     <= 0; s2_sign_b_eff <= 0;
        s2_a_larger   <= 0;
        s2_a_raw      <= 0; s2_b_eff      <= 0;
        s2_scale_diff <= 0;
        s2_k_a        <= 0; s2_k_b        <= 0;
        s2_exp_a      <= 0; s2_exp_b      <= 0;
        s2_frac_a     <= 0; s2_frac_b     <= 0;
    end else begin
        s2_valid      <= s1_valid;
        s2_zero_a     <= s1_zero_a;
        s2_zero_b     <= s1_zero_b;
        s2_nar_a      <= s1_nar_a;
        s2_nar_b      <= s1_nar_b;
        s2_sign_a     <= s1_sign_a;
        s2_sign_b_eff <= s1_sign_b_eff;
        s2_a_larger   <= a_larger_c;
        s2_a_raw      <= s1_a_raw;
        s2_b_eff      <= s1_b_eff;
        s2_scale_diff <= scale_diff_c;
        s2_k_a        <= k_a_w;
        s2_k_b        <= k_b_w;
        s2_exp_a      <= exp_a_w;
        s2_exp_b      <= exp_b_w;
        s2_frac_a     <= frac_a_w;
        s2_frac_b     <= frac_b_w;
    end
end

// ════════════════════════════════════════════════════════════
//  STAGE 3 — alignment + add/subtract
// ════════════════════════════════════════════════════════════

reg [26:0] frac_a_aligned_c, frac_b_aligned_c;
reg        sign_larger_c;
reg [2:0]  exp_aligned_c;
reg signed [31:0] k_aligned_c;

always @(*) begin
    if (s2_a_larger) begin
        frac_a_aligned_c = s2_frac_a;
        exp_aligned_c    = s2_exp_a;
        k_aligned_c      = s2_k_a;
        sign_larger_c    = s2_sign_a;
        frac_b_aligned_c = (s2_scale_diff < 27) ?
            (s2_frac_b >> s2_scale_diff[4:0]) : 27'd0;
    end else begin
        frac_b_aligned_c = s2_frac_b;
        exp_aligned_c    = s2_exp_b;
        k_aligned_c      = s2_k_b;
        sign_larger_c    = s2_sign_b_eff;
        frac_a_aligned_c = (s2_scale_diff < 27) ?
            (s2_frac_a >> s2_scale_diff[4:0]) : 27'd0;
    end
end

reg [27:0] sum_raw_c;
reg        sign_result_c;

always @(*) begin
    sign_result_c = sign_larger_c;
    sum_raw_c     = 28'd0;

    if (s2_sign_a == s2_sign_b_eff) begin
        sum_raw_c     = {1'b0,frac_a_aligned_c} + {1'b0,frac_b_aligned_c};
        sign_result_c = sign_larger_c;
    end else begin
        if (s2_a_larger) begin
            if (frac_a_aligned_c >= frac_b_aligned_c)
                sum_raw_c = {1'b0, frac_a_aligned_c - frac_b_aligned_c};
            else begin
                sum_raw_c     = {1'b0, frac_b_aligned_c - frac_a_aligned_c};
                sign_result_c = s2_sign_b_eff;
            end
        end else begin
            if (frac_b_aligned_c >= frac_a_aligned_c)
                sum_raw_c = {1'b0, frac_b_aligned_c - frac_a_aligned_c};
            else begin
                sum_raw_c     = {1'b0, frac_a_aligned_c - frac_b_aligned_c};
                sign_result_c = s2_sign_a;
            end
        end
    end
end

reg        s3_valid;
reg        s3_zero_a, s3_zero_b, s3_nar_a, s3_nar_b;
reg [31:0] s3_a_raw, s3_b_eff;
reg [27:0] s3_sum_raw;
reg        s3_sign_result;
reg [2:0]  s3_exp_aligned;
reg signed [31:0] s3_k_aligned;

always @(posedge clk) begin
    if (rst) begin
        s3_valid       <= 0;
        s3_zero_a      <= 0; s3_zero_b     <= 0;
        s3_nar_a       <= 0; s3_nar_b      <= 0;
        s3_a_raw       <= 0; s3_b_eff      <= 0;
        s3_sum_raw     <= 0;
        s3_sign_result <= 0;
        s3_exp_aligned <= 0;
        s3_k_aligned   <= 0;
    end else begin
        s3_valid       <= s2_valid;
        s3_zero_a      <= s2_zero_a;
        s3_zero_b      <= s2_zero_b;
        s3_nar_a       <= s2_nar_a;
        s3_nar_b       <= s2_nar_b;
        s3_a_raw       <= s2_a_raw;
        s3_b_eff       <= s2_b_eff;
        s3_sum_raw     <= sum_raw_c;
        s3_sign_result <= sign_result_c;
        s3_exp_aligned <= exp_aligned_c;
        s3_k_aligned   <= k_aligned_c;
    end
end

// ════════════════════════════════════════════════════════════
//  STAGE 4 — normalisation
// ════════════════════════════════════════════════════════════

wire        carry_c   = s3_sum_raw[27];
wire [26:0] sum_mag_c = s3_sum_raw[26:0];

function [4:0] lzd27;
    input [26:0] x;
    begin
             if (x[26]) lzd27=5'd0;  else if (x[25]) lzd27=5'd1;
        else if (x[24]) lzd27=5'd2;  else if (x[23]) lzd27=5'd3;
        else if (x[22]) lzd27=5'd4;  else if (x[21]) lzd27=5'd5;
        else if (x[20]) lzd27=5'd6;  else if (x[19]) lzd27=5'd7;
        else if (x[18]) lzd27=5'd8;  else if (x[17]) lzd27=5'd9;
        else if (x[16]) lzd27=5'd10; else if (x[15]) lzd27=5'd11;
        else if (x[14]) lzd27=5'd12; else if (x[13]) lzd27=5'd13;
        else if (x[12]) lzd27=5'd14; else if (x[11]) lzd27=5'd15;
        else if (x[10]) lzd27=5'd16; else if (x[9])  lzd27=5'd17;
        else if (x[8])  lzd27=5'd18; else if (x[7])  lzd27=5'd19;
        else if (x[6])  lzd27=5'd20; else if (x[5])  lzd27=5'd21;
        else if (x[4])  lzd27=5'd22; else if (x[3])  lzd27=5'd23;
        else if (x[2])  lzd27=5'd24; else if (x[1])  lzd27=5'd25;
        else if (x[0])  lzd27=5'd26; else            lzd27=5'd27;
    end
endfunction

wire [4:0] lz_c = lzd27(sum_mag_c);

reg [26:0] mant_norm_c;
reg [2:0]  exp_norm_c;
reg signed [31:0] k_norm_c;

always @(*) begin
    mant_norm_c = sum_mag_c;
    exp_norm_c  = s3_exp_aligned;
    k_norm_c    = s3_k_aligned;

    if (carry_c) begin
        mant_norm_c = {1'b1, sum_mag_c[26:1]};
        if (s3_exp_aligned == 3'b111) begin
            exp_norm_c = 3'b000;
            k_norm_c   = s3_k_aligned + 32'sd1;
        end else begin
            exp_norm_c = s3_exp_aligned + 3'd1;
        end
    end else if (sum_mag_c != 27'd0 && !sum_mag_c[26]) begin
        mant_norm_c = sum_mag_c << lz_c;
        if ({2'b0, s3_exp_aligned} >= lz_c) begin
            exp_norm_c = s3_exp_aligned - lz_c[2:0];
        end else begin
            begin : norm_borrow
                reg [4:0] borrow_amt;
                reg [4:0] new_exp_wide;
                borrow_amt   = lz_c - {2'b0, s3_exp_aligned};
                k_norm_c     = s3_k_aligned -
                    (((borrow_amt - 5'd1) >> 3) + 32'sd1);
                new_exp_wide = ({2'b0, s3_exp_aligned} + 5'd8 -
                    {2'b0, lz_c[2:0]});
                exp_norm_c   = new_exp_wide[2:0];
            end
        end
    end
end

// Clamp k_norm to [-5..+4] before storing —
// keeps s4_k narrow so encode_blk comparisons are static
wire signed [4:0] k_norm_clamped =
    (k_norm_c > 4)  ? 5'sd4  :
    (k_norm_c < -5) ? -5'sd5 : k_norm_c[4:0];

reg        s4_valid;
reg        s4_zero_a, s4_zero_b, s4_nar_a, s4_nar_b;
reg [31:0] s4_a_raw, s4_b_eff;
reg [26:0] s4_mant;
reg [2:0]  s4_exp;
reg signed [4:0] s4_k;     // 5-bit: range [-5..+4] fully representable
reg        s4_sign;

always @(posedge clk) begin
    if (rst) begin
        s4_valid  <= 0;
        s4_zero_a <= 0; s4_zero_b <= 0;
        s4_nar_a  <= 0; s4_nar_b  <= 0;
        s4_a_raw  <= 0; s4_b_eff  <= 0;
        s4_mant   <= 0; s4_exp    <= 0;
        s4_k      <= 0; s4_sign   <= 0;
    end else begin
        s4_valid  <= s3_valid;
        s4_zero_a <= s3_zero_a;
        s4_zero_b <= s3_zero_b;
        s4_nar_a  <= s3_nar_a;
        s4_nar_b  <= s3_nar_b;
        s4_a_raw  <= s3_a_raw;
        s4_b_eff  <= s3_b_eff;
        s4_mant   <= mant_norm_c;
        s4_exp    <= exp_norm_c;
        s4_k      <= k_norm_clamped;
        s4_sign   <= s3_sign_result;
    end
end

// ════════════════════════════════════════════════════════════
//  STAGE 5 — re-encode
//  All loops replaced with flat if-statements.
// ════════════════════════════════════════════════════════════

reg [31:0] p_next;

always @(*) begin
    p_next = POSIT_ZERO;

    if (s4_nar_a || s4_nar_b) begin
        p_next = POSIT_NAR;

    end else if (s4_zero_a && s4_zero_b) begin
        p_next = POSIT_ZERO;

    end else if (s4_zero_a) begin
        p_next = s4_b_eff;

    end else if (s4_zero_b) begin
        p_next = s4_a_raw;

    end else if (s4_mant == 27'd0) begin
        p_next = POSIT_ZERO;

    end else if (s4_k > MAX_K) begin
        p_next = s4_sign ? POSIT_MINNEG : POSIT_MAXPOS;

    end else if (s4_k < MIN_K) begin
        p_next = POSIT_ZERO;

    end else begin
        begin : encode_blk
            reg [31:0]       mag5;
            reg [4:0]        pos5;
            reg signed [4:0] k_int;

            mag5  = 32'b0;
            pos5  = 5'd30;
            k_int = s4_k;

            // ── Regime ──────────────────────────────────────
            if (k_int >= 0) begin
                if (k_int >= 0 && pos5<=30) begin mag5[pos5]=1'b1; pos5=pos5-1; end
                if (k_int >= 1 && pos5<=30) begin mag5[pos5]=1'b1; pos5=pos5-1; end
                if (k_int >= 2 && pos5<=30) begin mag5[pos5]=1'b1; pos5=pos5-1; end
                if (k_int >= 3 && pos5<=30) begin mag5[pos5]=1'b1; pos5=pos5-1; end
                if (k_int >= 4 && pos5<=30) begin mag5[pos5]=1'b1; pos5=pos5-1; end
                if (pos5<=30) begin mag5[pos5]=1'b0; pos5=pos5-1; end
            end else begin
                if (k_int <= -1 && pos5<=30) begin mag5[pos5]=1'b0; pos5=pos5-1; end
                if (k_int <= -2 && pos5<=30) begin mag5[pos5]=1'b0; pos5=pos5-1; end
                if (k_int <= -3 && pos5<=30) begin mag5[pos5]=1'b0; pos5=pos5-1; end
                if (k_int <= -4 && pos5<=30) begin mag5[pos5]=1'b0; pos5=pos5-1; end
                if (k_int <= -5 && pos5<=30) begin mag5[pos5]=1'b0; pos5=pos5-1; end
                if (pos5<=30) begin mag5[pos5]=1'b1; pos5=pos5-1; end
            end

            // ── Exponent (ES=3, MSB first) ──────────────────
            if (pos5<=30) begin mag5[pos5]=s4_exp[2]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_exp[1]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_exp[0]; pos5=pos5-1; end

            // ── Fraction (26 bits [25:0], MSB first) ────────
            if (pos5<=30) begin mag5[pos5]=s4_mant[25]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[24]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[23]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[22]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[21]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[20]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[19]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[18]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[17]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[16]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[15]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[14]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[13]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[12]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[11]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[10]; pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[9];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[8];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[7];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[6];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[5];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[4];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[3];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[2];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[1];  pos5=pos5-1; end
            if (pos5<=30) begin mag5[pos5]=s4_mant[0];  pos5=pos5-1; end

            p_next = s4_sign ? (~mag5 + 1'b1) : mag5;
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        p <= POSIT_ZERO; valid_out <= 1'b0;
    end else begin
        p <= p_next; valid_out <= s4_valid;
    end
end

endmodule
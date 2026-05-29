module posit_mult_32bit (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] p,
    output reg         valid_out
);

localparam [31:0] POSIT_ZERO   = 32'h00000000;
localparam [31:0] POSIT_NAR    = 32'h80000000;
localparam [31:0] POSIT_MAXPOS = 32'h7FFFFFFF;
localparam [31:0] POSIT_MINNEG = 32'h80000001;
localparam signed MAX_K = 4;
localparam signed MIN_K = -5;

// ════════════════════════════════════════════════════════════
//  STAGE 1 — data_extract + special-case detection
// ════════════════════════════════════════════════════════════

wire zero_a_c   = (a == POSIT_ZERO);
wire zero_b_c   = (b == POSIT_ZERO);
wire nar_a_c    = (a == POSIT_NAR);
wire nar_b_c    = (b == POSIT_NAR);
wire maxpos_a_c = (a == POSIT_MAXPOS) || (a == POSIT_MINNEG);
wire maxpos_b_c = (b == POSIT_MAXPOS) || (b == POSIT_MINNEG);
wire sign_p_c   = a[31] ^ b[31];
wire [31:0] mag_a_c = a[31] ? (~a + 1'b1) : a;
wire [31:0] mag_b_c = b[31] ? (~b + 1'b1) : b;

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

reg s1_zero_a, s1_zero_b, s1_nar_a, s1_nar_b;
reg s1_maxpos_a, s1_maxpos_b, s1_sign_p;

always @(posedge clk) begin
    if (rst) begin
        s1_zero_a   <= 0; s1_zero_b   <= 0;
        s1_nar_a    <= 0; s1_nar_b    <= 0;
        s1_maxpos_a <= 0; s1_maxpos_b <= 0;
        s1_sign_p   <= 0;
    end else begin
        s1_zero_a   <= zero_a_c;   s1_zero_b   <= zero_b_c;
        s1_nar_a    <= nar_a_c;    s1_nar_b    <= nar_b_c;
        s1_maxpos_a <= maxpos_a_c; s1_maxpos_b <= maxpos_b_c;
        s1_sign_p   <= sign_p_c;
    end
end

// ════════════════════════════════════════════════════════════
//  STAGE 2 — scale addition + 27x27 mantissa multiply
// ════════════════════════════════════════════════════════════

wire signed [11:0] scale_a_c = ({k_a_w[10], k_a_w[10:0]} <<< 3) + {9'b0, exp_a_w};
wire signed [11:0] scale_b_c = ({k_b_w[10], k_b_w[10:0]} <<< 3) + {9'b0, exp_b_w};

wire signed [11:0] scale_s_c  = scale_a_c + scale_b_c;
wire        [53:0] mant_prod_c = frac_a_w * frac_b_w;

reg        s2_valid;
reg        s2_zero_a, s2_zero_b, s2_nar_a, s2_nar_b;
reg        s2_maxpos_a, s2_maxpos_b, s2_sign_p;
reg signed [11:0] s2_scale_s;
reg        [53:0] s2_mant_prod;

always @(posedge clk) begin
    if (rst) begin
        s2_valid     <= 0;
        s2_zero_a    <= 0; s2_zero_b    <= 0;
        s2_nar_a     <= 0; s2_nar_b     <= 0;
        s2_maxpos_a  <= 0; s2_maxpos_b  <= 0;
        s2_sign_p    <= 0;
        s2_scale_s   <= 0; s2_mant_prod <= 0;
    end else begin
        s2_valid     <= s1_valid;
        s2_zero_a    <= s1_zero_a;   s2_zero_b   <= s1_zero_b;
        s2_nar_a     <= s1_nar_a;    s2_nar_b    <= s1_nar_b;
        s2_maxpos_a  <= s1_maxpos_a; s2_maxpos_b <= s1_maxpos_b;
        s2_sign_p    <= s1_sign_p;
        s2_scale_s   <= scale_s_c;
        s2_mant_prod <= mant_prod_c;
    end
end

// ════════════════════════════════════════════════════════════
//  STAGE 3 — normalise + clamp
// ════════════════════════════════════════════════════════════

wire        carry_c    = s2_mant_prod[53];
wire [26:0] mant_n_c   = carry_c ? s2_mant_prod[53:27] : s2_mant_prod[52:26];
wire signed [11:0] scale_n_c = carry_c ? (s2_scale_s + 12'sd1) : s2_scale_s;

wire signed [11:0] k_n_c   = $signed(scale_n_c) >>> 3;
wire [2:0]         exp_n_c = scale_n_c[2:0];

wire overflow_c  = ($signed(k_n_c) > MAX_K) ||
                   ($signed(k_n_c) == MAX_K && exp_n_c != 3'b000) ||
                   s2_maxpos_a || s2_maxpos_b;
wire underflow_c = ($signed(k_n_c) < MIN_K);

reg        s3_valid;
reg        s3_zero_a, s3_zero_b, s3_nar_a, s3_nar_b, s3_sign_p;
reg signed [4:0]  s3_k;      // clamped to [-5..+4], 5 bits sufficient
reg [2:0]  s3_exp;
reg [26:0] s3_mant;
reg        s3_overflow, s3_underflow;

always @(posedge clk) begin
    if (rst) begin
        s3_valid     <= 0;
        s3_zero_a    <= 0; s3_zero_b    <= 0;
        s3_nar_a     <= 0; s3_nar_b     <= 0;
        s3_sign_p    <= 0;
        s3_k         <= 0; s3_exp       <= 0;
        s3_mant      <= 0;
        s3_overflow  <= 0; s3_underflow <= 0;
    end else begin
        s3_valid     <= s2_valid;
        s3_zero_a    <= s2_zero_a;  s3_zero_b <= s2_zero_b;
        s3_nar_a     <= s2_nar_a;   s3_nar_b  <= s2_nar_b;
        s3_sign_p    <= s2_sign_p;
        s3_k         <= k_n_c[4:0];  // safe: overflow/underflow guards above
        s3_exp       <= exp_n_c;
        s3_mant      <= mant_n_c;
        s3_overflow  <= overflow_c;
        s3_underflow <= underflow_c;
    end
end

// ════════════════════════════════════════════════════════════
//  STAGE 4 — re-encode + output FF
//  All loops replaced with flat if-statements so Quartus can
//  statically evaluate every branch — no non-constant bounds.
// ════════════════════════════════════════════════════════════

reg [31:0] p_next;

always @(*) begin
    p_next = POSIT_ZERO;

    if (s3_nar_a || s3_nar_b) begin
        p_next = POSIT_NAR;

    end else if (s3_zero_a || s3_zero_b) begin
        p_next = POSIT_ZERO;

    end else if (s3_overflow) begin
        p_next = s3_sign_p ? POSIT_MINNEG : POSIT_MAXPOS;

    end else if (s3_underflow) begin
        p_next = POSIT_ZERO;

    end else begin
        begin : encode_blk
            reg [31:0] mag4;
            reg [4:0]  pos4;
            reg signed [4:0] k_int;

            mag4  = 32'b0;
            pos4  = 5'd30;
            k_int = s3_k;

            // ── Regime ──────────────────────────────────────
            if (k_int >= 0) begin
                // k ones followed by a zero terminator
                if (k_int >= 0 && pos4 <= 30) begin mag4[pos4]=1'b1; pos4=pos4-1; end
                if (k_int >= 1 && pos4 <= 30) begin mag4[pos4]=1'b1; pos4=pos4-1; end
                if (k_int >= 2 && pos4 <= 30) begin mag4[pos4]=1'b1; pos4=pos4-1; end
                if (k_int >= 3 && pos4 <= 30) begin mag4[pos4]=1'b1; pos4=pos4-1; end
                if (k_int >= 4 && pos4 <= 30) begin mag4[pos4]=1'b1; pos4=pos4-1; end
                if (pos4 <= 30) begin mag4[pos4]=1'b0; pos4=pos4-1; end
            end else begin
                // -k zeros followed by a one terminator
                if (k_int <= -1 && pos4 <= 30) begin mag4[pos4]=1'b0; pos4=pos4-1; end
                if (k_int <= -2 && pos4 <= 30) begin mag4[pos4]=1'b0; pos4=pos4-1; end
                if (k_int <= -3 && pos4 <= 30) begin mag4[pos4]=1'b0; pos4=pos4-1; end
                if (k_int <= -4 && pos4 <= 30) begin mag4[pos4]=1'b0; pos4=pos4-1; end
                if (k_int <= -5 && pos4 <= 30) begin mag4[pos4]=1'b0; pos4=pos4-1; end
                if (pos4 <= 30) begin mag4[pos4]=1'b1; pos4=pos4-1; end
            end

            // ── Exponent (ES=3, MSB first) ──────────────────
            if (pos4 <= 30) begin mag4[pos4]=s3_exp[2]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_exp[1]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_exp[0]; pos4=pos4-1; end

            // ── Fraction (26 bits [25:0], MSB first) ────────
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[25]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[24]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[23]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[22]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[21]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[20]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[19]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[18]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[17]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[16]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[15]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[14]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[13]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[12]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[11]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[10]; pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[9];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[8];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[7];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[6];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[5];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[4];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[3];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[2];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[1];  pos4=pos4-1; end
            if (pos4 <= 30) begin mag4[pos4]=s3_mant[0];  pos4=pos4-1; end

            p_next = s3_sign_p ? (~mag4 + 1'b1) : mag4;
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        p <= POSIT_ZERO; valid_out <= 1'b0;
    end else begin
        p <= p_next; valid_out <= s3_valid;
    end
end

endmodule
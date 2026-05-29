module posit_butterfly_unit (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [31:0] Ar, Ai,      // A = complex input
    input  wire [31:0] Br, Bi,      // B = complex input
    input  wire [31:0] Wr, Wi,      // W = twiddle factor (unchanged)
    output wire [31:0] Xr, Xi,      // X = A + B*W
    output wire [31:0] Yr, Yi,      // Y = A - B*W
    output wire        valid_out
);

// ════════════════════════════════════════════════════════════
//  Stage 1 — Four twiddle multiplications
//  Inputs: Br,Bi,Wr,Wi (cycle 0)
//  Outputs: m1..m4 (cycle 4, via mult_valid)
// ════════════════════════════════════════════════════════════

wire [31:0] m1, m2, m3, m4;
wire mult_valid; // all four mults share the same latency

posit_mult_32bit mul_br_wr (
    .clk(clk), .rst(rst), .valid_in(valid_in),
    .a(Br), .b(Wr), .p(m1), .valid_out(mult_valid)
);
posit_mult_32bit mul_bi_wi (
    .clk(clk), .rst(rst), .valid_in(valid_in),
    .a(Bi), .b(Wi), .p(m2), .valid_out()
);
posit_mult_32bit mul_br_wi (
    .clk(clk), .rst(rst), .valid_in(valid_in),
    .a(Br), .b(Wi), .p(m3), .valid_out()
);
posit_mult_32bit mul_bi_wr (
    .clk(clk), .rst(rst), .valid_in(valid_in),
    .a(Bi), .b(Wr), .p(m4), .valid_out()
);

// ════════════════════════════════════════════════════════════
//  Stage 2 — Complex product: BW = B * W
//    BW_real = Br*Wr - Bi*Wi = m1 - m2
//    BW_imag = Br*Wi + Bi*Wr = m3 + m4
//  Inputs applied at cycle 4 (mult_valid)
//  Outputs valid at cycle 4+5 = 9 (bw_valid)
// ════════════════════════════════════════════════════════════

wire [31:0] BW_real, BW_imag;
wire bw_valid;

posit_addsub_32bit sub_real (
    .clk(clk), .rst(rst), .valid_in(mult_valid),
    .a(m1), .b(m2), .op(1'b1),
    .p(BW_real), .valid_out(bw_valid)
);
posit_addsub_32bit add_imag (
    .clk(clk), .rst(rst), .valid_in(mult_valid),
    .a(m3), .b(m4), .op(1'b0),
    .p(BW_imag), .valid_out()
);

// ════════════════════════════════════════════════════════════
//  A delay chain — 9 pipeline registers
//  A applied at cycle 0 must be stable at cycle 9 to align
//  with BW_real/BW_imag at the Stage-3 addsub inputs.
//  9 FF stages exactly match the 4 (mult) + 5 (addsub) path.
// ════════════════════════════════════════════════════════════

reg [31:0] Ar_d [1:9];
reg [31:0] Ai_d [1:9];

integer di;
always @(posedge clk) begin
    if (rst) begin
        for (di = 1; di <= 9; di = di + 1) begin
            Ar_d[di] <= 32'b0;
            Ai_d[di] <= 32'b0;
        end
    end else begin
        Ar_d[1] <= Ar;
        Ai_d[1] <= Ai;
        for (di = 2; di <= 9; di = di + 1) begin
            Ar_d[di] <= Ar_d[di-1];
            Ai_d[di] <= Ai_d[di-1];
        end
    end
end

// ════════════════════════════════════════════════════════════
//  Stage 3 — Butterfly outputs
//    X = A + B*W  →  Xr = Ar + BW_real,  Xi = Ai + BW_imag
//    Y = A - B*W  →  Yr = Ar - BW_real,  Yi = Ai - BW_imag
//  Inputs applied at cycle 9 (bw_valid, Ar_d[9]/Ai_d[9])
//  Outputs valid at cycle 9+5 = 14 (valid_out)
// ════════════════════════════════════════════════════════════

posit_addsub_32bit add_xr (
    .clk(clk), .rst(rst), .valid_in(bw_valid),
    .a(Ar_d[9]), .b(BW_real), .op(1'b0),
    .p(Xr), .valid_out(valid_out)
);
posit_addsub_32bit add_xi (
    .clk(clk), .rst(rst), .valid_in(bw_valid),
    .a(Ai_d[9]), .b(BW_imag), .op(1'b0),
    .p(Xi), .valid_out()
);
posit_addsub_32bit sub_yr (
    .clk(clk), .rst(rst), .valid_in(bw_valid),
    .a(Ar_d[9]), .b(BW_real), .op(1'b1),
    .p(Yr), .valid_out()
);
posit_addsub_32bit sub_yi (
    .clk(clk), .rst(rst), .valid_in(bw_valid),
    .a(Ai_d[9]), .b(BW_imag), .op(1'b1),
    .p(Yi), .valid_out()
);

endmodule

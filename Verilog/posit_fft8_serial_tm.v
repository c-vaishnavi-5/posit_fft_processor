module posit_fft8_pipeline (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,

    // Bit-reversed inputs (natural order fed in, bit-reversal wired externally)
    input  wire [31:0] x0r, x0i,  // bit-reversed index 0
    input  wire [31:0] x1r, x1i,
    input  wire [31:0] x2r, x2i,
    input  wire [31:0] x3r, x3i,
    input  wire [31:0] x4r, x4i,
    input  wire [31:0] x5r, x5i,
    input  wire [31:0] x6r, x6i,
    input  wire [31:0] x7r, x7i,

    output wire [31:0] X0r, X0i,
    output wire [31:0] X1r, X1i,
    output wire [31:0] X2r, X2i,
    output wire [31:0] X3r, X3i,
    output wire [31:0] X4r, X4i,
    output wire [31:0] X5r, X5i,
    output wire [31:0] X6r, X6i,
    output wire [31:0] X7r, X7i,
    output wire        valid_out
);

// Twiddle constants
localparam [31:0] W0R=32'h40000000, W0I=32'h00000000;
localparam [31:0] W1R=32'h3DA8279A, W1I=32'hC257D866;
localparam [31:0] W2R=32'h00000000, W2I=32'hC0000000;
localparam [31:0] W3R=32'hC257D866, W3I=32'hC257D866;

// ── Stage 1 outputs (4 butterflies, all twiddle = W0) ──
wire [31:0] s1_0r,s1_0i,s1_1r,s1_1i;  // BF(x0,x1,W0)
wire [31:0] s1_2r,s1_2i,s1_3r,s1_3i;  // BF(x2,x3,W0)
wire [31:0] s1_4r,s1_4i,s1_5r,s1_5i;  // BF(x4,x5,W0)
wire [31:0] s1_6r,s1_6i,s1_7r,s1_7i;  // BF(x6,x7,W0)
wire s1_valid;

posit_butterfly_unit bf1_0(.clk(clk),.rst(rst),.valid_in(valid_in),
    .Ar(x0r),.Ai(x0i),.Br(x1r),.Bi(x1i),.Wr(W0R),.Wi(W0I),
    .Xr(s1_0r),.Xi(s1_0i),.Yr(s1_1r),.Yi(s1_1i),.valid_out(s1_valid));

posit_butterfly_unit bf1_1(.clk(clk),.rst(rst),.valid_in(valid_in),
    .Ar(x2r),.Ai(x2i),.Br(x3r),.Bi(x3i),.Wr(W0R),.Wi(W0I),
    .Xr(s1_2r),.Xi(s1_2i),.Yr(s1_3r),.Yi(s1_3i),.valid_out());

posit_butterfly_unit bf1_2(.clk(clk),.rst(rst),.valid_in(valid_in),
    .Ar(x4r),.Ai(x4i),.Br(x5r),.Bi(x5i),.Wr(W0R),.Wi(W0I),
    .Xr(s1_4r),.Xi(s1_4i),.Yr(s1_5r),.Yi(s1_5i),.valid_out());

posit_butterfly_unit bf1_3(.clk(clk),.rst(rst),.valid_in(valid_in),
    .Ar(x6r),.Ai(x6i),.Br(x7r),.Bi(x7i),.Wr(W0R),.Wi(W0I),
    .Xr(s1_6r),.Xi(s1_6i),.Yr(s1_7r),.Yi(s1_7i),.valid_out());

// ── Stage 2 (4 butterflies, twiddles W0 and W2) ──
wire [31:0] s2_0r,s2_0i,s2_2r,s2_2i;  // BF(s1[0],s1[2],W0)
wire [31:0] s2_1r,s2_1i,s2_3r,s2_3i;  // BF(s1[1],s1[3],W2)
wire [31:0] s2_4r,s2_4i,s2_6r,s2_6i;  // BF(s1[4],s1[6],W0)
wire [31:0] s2_5r,s2_5i,s2_7r,s2_7i;  // BF(s1[5],s1[7],W2)
wire s2_valid;

posit_butterfly_unit bf2_0(.clk(clk),.rst(rst),.valid_in(s1_valid),
    .Ar(s1_0r),.Ai(s1_0i),.Br(s1_2r),.Bi(s1_2i),.Wr(W0R),.Wi(W0I),
    .Xr(s2_0r),.Xi(s2_0i),.Yr(s2_2r),.Yi(s2_2i),.valid_out(s2_valid));

posit_butterfly_unit bf2_1(.clk(clk),.rst(rst),.valid_in(s1_valid),
    .Ar(s1_1r),.Ai(s1_1i),.Br(s1_3r),.Bi(s1_3i),.Wr(W2R),.Wi(W2I),
    .Xr(s2_1r),.Xi(s2_1i),.Yr(s2_3r),.Yi(s2_3i),.valid_out());

posit_butterfly_unit bf2_2(.clk(clk),.rst(rst),.valid_in(s1_valid),
    .Ar(s1_4r),.Ai(s1_4i),.Br(s1_6r),.Bi(s1_6i),.Wr(W0R),.Wi(W0I),
    .Xr(s2_4r),.Xi(s2_4i),.Yr(s2_6r),.Yi(s2_6i),.valid_out());

posit_butterfly_unit bf2_3(.clk(clk),.rst(rst),.valid_in(s1_valid),
    .Ar(s1_5r),.Ai(s1_5i),.Br(s1_7r),.Bi(s1_7i),.Wr(W2R),.Wi(W2I),
    .Xr(s2_5r),.Xi(s2_5i),.Yr(s2_7r),.Yi(s2_7i),.valid_out());

// ── Stage 3 (4 butterflies, twiddles W0..W3) ──
posit_butterfly_unit bf3_0(.clk(clk),.rst(rst),.valid_in(s2_valid),
    .Ar(s2_0r),.Ai(s2_0i),.Br(s2_4r),.Bi(s2_4i),.Wr(W0R),.Wi(W0I),
    .Xr(X0r),.Xi(X0i),.Yr(X4r),.Yi(X4i),.valid_out(valid_out));

posit_butterfly_unit bf3_1(.clk(clk),.rst(rst),.valid_in(s2_valid),
    .Ar(s2_1r),.Ai(s2_1i),.Br(s2_5r),.Bi(s2_5i),.Wr(W1R),.Wi(W1I),
    .Xr(X1r),.Xi(X1i),.Yr(X5r),.Yi(X5i),.valid_out());

posit_butterfly_unit bf3_2(.clk(clk),.rst(rst),.valid_in(s2_valid),
    .Ar(s2_2r),.Ai(s2_2i),.Br(s2_6r),.Bi(s2_6i),.Wr(W2R),.Wi(W2I),
    .Xr(X2r),.Xi(X2i),.Yr(X6r),.Yi(X6i),.valid_out());

posit_butterfly_unit bf3_3(.clk(clk),.rst(rst),.valid_in(s2_valid),
    .Ar(s2_3r),.Ai(s2_3i),.Br(s2_7r),.Bi(s2_7i),.Wr(W3R),.Wi(W3I),
    .Xr(X3r),.Xi(X3i),.Yr(X7r),.Yi(X7i),.valid_out());

endmodule

// =============================================================================
// posit_fft8_serial_tm.v — Time-Multiplexed 8-point DIT FFT (Posit32, ES=3)
// =============================================================================

module posit_fft8_serial_tm (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,

    input  wire [31:0] br0_r, br0_i,
    input  wire [31:0] br1_r, br1_i,
    input  wire [31:0] br2_r, br2_i,
    input  wire [31:0] br3_r, br3_i,
    input  wire [31:0] br4_r, br4_i,
    input  wire [31:0] br5_r, br5_i,
    input  wire [31:0] br6_r, br6_i,
    input  wire [31:0] br7_r, br7_i,

    output reg  [31:0] Xr0, Xi0,
    output reg  [31:0] Xr1, Xi1,
    output reg  [31:0] Xr2, Xi2,
    output reg  [31:0] Xr3, Xi3,
    output reg  [31:0] Xr4, Xi4,
    output reg  [31:0] Xr5, Xi5,
    output reg  [31:0] Xr6, Xi6,
    output reg  [31:0] Xr7, Xi7,

    output reg         done
);

// =============================================================================
// Twiddle factors — Posit(32,3)
// =============================================================================
localparam [31:0] W0R = 32'h40000000;  //  1.0
localparam [31:0] W0I = 32'h00000000;  //  0.0
localparam [31:0] W1R = 32'h3DA8279A;  //  0.70710678
localparam [31:0] W1I = 32'hC257D866;  // -0.70710678
localparam [31:0] W2R = 32'h00000000;  //  0.0
localparam [31:0] W2I = 32'hC0000000;  // -1.0
localparam [31:0] W3R = 32'hC257D866;  // -0.70710678
localparam [31:0] W3I = 32'hC257D866;  // -0.70710678

// =============================================================================
// Node storage
// =============================================================================
reg [31:0] s0r [0:7]; reg [31:0] s0i [0:7];
reg [31:0] s1r [0:7]; reg [31:0] s1i [0:7];
reg [31:0] s2r [0:7]; reg [31:0] s2i [0:7];

// =============================================================================
// FSM
// =============================================================================
localparam S_IDLE   = 2'd0;
localparam S_STAGE1 = 2'd1;
localparam S_STAGE2 = 2'd2;
localparam S_STAGE3 = 2'd3;

reg [1:0] state;


reg [4:0] cyc;

// =============================================================================
// bf_op mux
// =============================================================================
reg [1:0] bf_op;

wire [31:0] bf_Ar, bf_Ai, bf_Br, bf_Bi, bf_Wr, bf_Wi;

assign bf_Ar =
    (state == S_STAGE1) ? (
        (bf_op==2'd0) ? s0r[0] : (bf_op==2'd1) ? s0r[2] :
        (bf_op==2'd2) ? s0r[4] : s0r[6] )
  : (state == S_STAGE2) ? (
        (bf_op==2'd0) ? s1r[0] : (bf_op==2'd1) ? s1r[1] :
        (bf_op==2'd2) ? s1r[4] : s1r[5] )
  : ( (bf_op==2'd0) ? s2r[0] : (bf_op==2'd1) ? s2r[1] :
        (bf_op==2'd2) ? s2r[2] : s2r[3] );

assign bf_Ai =
    (state == S_STAGE1) ? (
        (bf_op==2'd0) ? s0i[0] : (bf_op==2'd1) ? s0i[2] :
        (bf_op==2'd2) ? s0i[4] : s0i[6] )
  : (state == S_STAGE2) ? (
        (bf_op==2'd0) ? s1i[0] : (bf_op==2'd1) ? s1i[1] :
        (bf_op==2'd2) ? s1i[4] : s1i[5] )
  : ( (bf_op==2'd0) ? s2i[0] : (bf_op==2'd1) ? s2i[1] :
        (bf_op==2'd2) ? s2i[2] : s2i[3] );

assign bf_Br =
    (state == S_STAGE1) ? (
        (bf_op==2'd0) ? s0r[1] : (bf_op==2'd1) ? s0r[3] :
        (bf_op==2'd2) ? s0r[5] : s0r[7] )
  : (state == S_STAGE2) ? (
        (bf_op==2'd0) ? s1r[2] : (bf_op==2'd1) ? s1r[3] :
        (bf_op==2'd2) ? s1r[6] : s1r[7] )
  : ( (bf_op==2'd0) ? s2r[4] : (bf_op==2'd1) ? s2r[5] :
        (bf_op==2'd2) ? s2r[6] : s2r[7] );

assign bf_Bi =
    (state == S_STAGE1) ? (
        (bf_op==2'd0) ? s0i[1] : (bf_op==2'd1) ? s0i[3] :
        (bf_op==2'd2) ? s0i[5] : s0i[7] )
  : (state == S_STAGE2) ? (
        (bf_op==2'd0) ? s1i[2] : (bf_op==2'd1) ? s1i[3] :
        (bf_op==2'd2) ? s1i[6] : s1i[7] )
  : ( (bf_op==2'd0) ? s2i[4] : (bf_op==2'd1) ? s2i[5] :
        (bf_op==2'd2) ? s2i[6] : s2i[7] );

assign bf_Wr =
    (state == S_STAGE1) ? W0R
  : (state == S_STAGE2) ? (bf_op[0] ? W2R : W0R)
  : (bf_op==2'd0) ? W0R : (bf_op==2'd1) ? W1R :
    (bf_op==2'd2) ? W2R : W3R;

assign bf_Wi =
    (state == S_STAGE1) ? W0I
  : (state == S_STAGE2) ? (bf_op[0] ? W2I : W0I)
  : (bf_op==2'd0) ? W0I : (bf_op==2'd1) ? W1I :
    (bf_op==2'd2) ? W2I : W3I;

// =============================================================================
// Single butterfly unit (14-cycle pipeline)
// =============================================================================
wire [31:0] bf_Xr, bf_Xi, bf_Yr, bf_Yi;

posit_butterfly_unit butterfly (
    .clk(clk), .rst(rst),
    .valid_in(1'b1),
    .Ar(bf_Ar), .Ai(bf_Ai),
    .Br(bf_Br), .Bi(bf_Bi),
    .Wr(bf_Wr), .Wi(bf_Wi),
    .Xr(bf_Xr), .Xi(bf_Xi),
    .Yr(bf_Yr), .Yi(bf_Yi),
    .valid_out()
);

// =============================================================================
// FSM

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= S_IDLE; cyc <= 0; done <= 0; bf_op <= 0;
        s0r[0]<=0; s0i[0]<=0; s0r[1]<=0; s0i[1]<=0;
        s0r[2]<=0; s0i[2]<=0; s0r[3]<=0; s0i[3]<=0;
        s0r[4]<=0; s0i[4]<=0; s0r[5]<=0; s0i[5]<=0;
        s0r[6]<=0; s0i[6]<=0; s0r[7]<=0; s0i[7]<=0;
        s1r[0]<=0; s1i[0]<=0; s1r[1]<=0; s1i[1]<=0;
        s1r[2]<=0; s1i[2]<=0; s1r[3]<=0; s1i[3]<=0;
        s1r[4]<=0; s1i[4]<=0; s1r[5]<=0; s1i[5]<=0;
        s1r[6]<=0; s1i[6]<=0; s1r[7]<=0; s1i[7]<=0;
        s2r[0]<=0; s2i[0]<=0; s2r[1]<=0; s2i[1]<=0;
        s2r[2]<=0; s2i[2]<=0; s2r[3]<=0; s2i[3]<=0;
        s2r[4]<=0; s2i[4]<=0; s2r[5]<=0; s2i[5]<=0;
        s2r[6]<=0; s2i[6]<=0; s2r[7]<=0; s2i[7]<=0;
        Xr0<=0; Xi0<=0; Xr1<=0; Xi1<=0;
        Xr2<=0; Xi2<=0; Xr3<=0; Xi3<=0;
        Xr4<=0; Xi4<=0; Xr5<=0; Xi5<=0;
        Xr6<=0; Xi6<=0; Xr7<=0; Xi7<=0;
    end else begin

        done <= 0;

        case (state)

        // -----------------------------------------------------------------
        S_IDLE: begin
            cyc   <= 0;
            bf_op <= 0;
            if (start) begin
                s0r[0]<=br0_r; s0i[0]<=br0_i;
                s0r[1]<=br1_r; s0i[1]<=br1_i;
                s0r[2]<=br2_r; s0i[2]<=br2_i;
                s0r[3]<=br3_r; s0i[3]<=br3_i;
                s0r[4]<=br4_r; s0i[4]<=br4_i;
                s0r[5]<=br5_r; s0i[5]<=br5_i;
                s0r[6]<=br6_r; s0i[6]<=br6_i;
                s0r[7]<=br7_r; s0i[7]<=br7_i;
                state <= S_STAGE1;
            end
        end

        // -----------------------------------------------------------------
        // S_STAGE1: 4 butterflies pairing (s0[0],s0[1])..(s0[6],s0[7])
        //   Launch  : cyc=0..3  → bf_op steps 0,1,2,3
        //   Drain   : cyc=4..13 → idle
        //   Collect : cyc=14..17 → store into s1[]
        // -----------------------------------------------------------------
        S_STAGE1: begin
            cyc <= cyc + 1;
            case (cyc)
                // Present window
                5'd0:  bf_op <= 2'd1;
                5'd1:  bf_op <= 2'd2;
                5'd2:  bf_op <= 2'd3;
                5'd3:  bf_op <= 2'd0;   // reset for next stage's mux

                // Collect window (pipeline drain = 14 cycles from launch)
                5'd14: begin
                    s1r[0]<=bf_Xr; s1i[0]<=bf_Xi;
                    s1r[1]<=bf_Yr; s1i[1]<=bf_Yi;
                end
                5'd15: begin
                    s1r[2]<=bf_Xr; s1i[2]<=bf_Xi;
                    s1r[3]<=bf_Yr; s1i[3]<=bf_Yi;
                end
                5'd16: begin
                    s1r[4]<=bf_Xr; s1i[4]<=bf_Xi;
                    s1r[5]<=bf_Yr; s1i[5]<=bf_Yi;
                end
                5'd17: begin
                    s1r[6]<=bf_Xr; s1i[6]<=bf_Xi;
                    s1r[7]<=bf_Yr; s1i[7]<=bf_Yi;
                    bf_op <= 2'd0;
                    state <= S_STAGE2; cyc <= 0;
                end
                default: ;  // cyc 4..13: draining
            endcase
        end

        // -----------------------------------------------------------------
        // S_STAGE2: 4 butterflies on stage-1 outputs
        //   op0: (s1[0],s1[2]) W0  → s2[0],s2[2]
        //   op1: (s1[1],s1[3]) W2  → s2[1],s2[3]
        //   op2: (s1[4],s1[6]) W0  → s2[4],s2[6]
        //   op3: (s1[5],s1[7]) W2  → s2[5],s2[7]
        // -----------------------------------------------------------------
        S_STAGE2: begin
            cyc <= cyc + 1;
            case (cyc)
                5'd0:  bf_op <= 2'd1;
                5'd1:  bf_op <= 2'd2;
                5'd2:  bf_op <= 2'd3;
                5'd3:  bf_op <= 2'd0;

                5'd14: begin
                    s2r[0]<=bf_Xr; s2i[0]<=bf_Xi;
                    s2r[2]<=bf_Yr; s2i[2]<=bf_Yi;
                end
                5'd15: begin
                    s2r[1]<=bf_Xr; s2i[1]<=bf_Xi;
                    s2r[3]<=bf_Yr; s2i[3]<=bf_Yi;
                end
                5'd16: begin
                    s2r[4]<=bf_Xr; s2i[4]<=bf_Xi;
                    s2r[6]<=bf_Yr; s2i[6]<=bf_Yi;
                end
                5'd17: begin
                    s2r[5]<=bf_Xr; s2i[5]<=bf_Xi;
                    s2r[7]<=bf_Yr; s2i[7]<=bf_Yi;
                    bf_op <= 2'd0;
                    state <= S_STAGE3; cyc <= 0;
                end
                default: ;
            endcase
        end

        // -----------------------------------------------------------------
        // S_STAGE3: final 4 butterflies → X[0..7]
        //   op0: (s2[0],s2[4]) W0  → X[0],X[4]
        //   op1: (s2[1],s2[5]) W1  → X[1],X[5]
        //   op2: (s2[2],s2[6]) W2  → X[2],X[6]
        //   op3: (s2[3],s2[7]) W3  → X[3],X[7]
        // -----------------------------------------------------------------
        S_STAGE3: begin
            cyc <= cyc + 1;
            case (cyc)
                5'd0:  bf_op <= 2'd1;
                5'd1:  bf_op <= 2'd2;
                5'd2:  bf_op <= 2'd3;
                5'd3:  bf_op <= 2'd0;

                5'd14: begin
                    Xr0<=bf_Xr; Xi0<=bf_Xi;
                    Xr4<=bf_Yr; Xi4<=bf_Yi;
                end
                5'd15: begin
                    Xr1<=bf_Xr; Xi1<=bf_Xi;
                    Xr5<=bf_Yr; Xi5<=bf_Yi;
                end
                5'd16: begin
                    Xr2<=bf_Xr; Xi2<=bf_Xi;
                    Xr6<=bf_Yr; Xi6<=bf_Yi;
                end
                5'd17: begin
                    Xr3<=bf_Xr; Xi3<=bf_Xi;
                    Xr7<=bf_Yr; Xi7<=bf_Yi;
                    done  <= 1;
                    state <= S_IDLE; cyc <= 0; bf_op <= 0;
                end
                default: ;
            endcase
        end

        endcase
    end
end

endmodule

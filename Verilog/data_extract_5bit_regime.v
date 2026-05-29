module data_extract_5bit_regime (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [31:0] flp_a,

    output reg         valid_out,
    output reg signed [31:0] ra_o,
    output reg [26:0]  fract_a,
    output reg [2:0]   exp_a
);

// ─── Combinational wires (pre-register) ───────────────────────────────────────
reg signed [31:0] ra_comb;
reg [26:0]        fract_comb;
reg [2:0]         exp_comb;
reg [30:0]        regime_a;
reg [25:0]        fract_1a;

always @(*) begin
    fract_1a   = 26'b0;
    regime_a   = flp_a[30:0];
    ra_comb    = 0;
    exp_comb   = 3'b000;
    fract_comb = 27'b0;

    casez (regime_a)

        // k=+4, no terminator (maxpos family)
        31'b11111_1????_?????_?????_?????_?????_?: begin
            ra_comb    = 4;
            exp_comb   = 3'b000;
            fract_comb = 27'b100_0000_0000_0000_0000_0000_0000;
        end

        // Regime = +4
        31'b11111_0????_?????_?????_?????_?????_?: begin
            ra_comb    = 4;
            exp_comb   = flp_a[24:22];
            fract_1a   = {4'b0000, flp_a[21:0]};
            fract_comb = {1'b1, fract_1a[21:0], 4'b0000};
        end

        // Regime = +3
        31'b11110_?????_?????_?????_?????_?????_?: begin
            ra_comb    = 3;
            exp_comb   = flp_a[25:23];
            fract_1a   = {3'b000, flp_a[22:0]};
            fract_comb = {1'b1, fract_1a[22:0], 3'b000};
        end

        // Regime = +2
        31'b1110?_?????_?????_?????_?????_?????_?: begin
            ra_comb    = 2;
            exp_comb   = flp_a[26:24];
            fract_1a   = {2'b00, flp_a[23:0]};
            fract_comb = {1'b1, fract_1a[23:0], 2'b00};
        end

        // Regime = +1
        31'b110??_?????_?????_?????_?????_?????_?: begin
            ra_comb    = 1;
            exp_comb   = flp_a[27:25];
            fract_1a   = {1'b0, flp_a[24:0]};
            fract_comb = {1'b1, fract_1a[24:0], 1'b0};
        end

        // Regime = 0
        31'b10???_?????_?????_?????_?????_?????_?: begin
            ra_comb    = 0;
            exp_comb   = flp_a[28:26];
            fract_comb = {1'b1, flp_a[25:0]};
        end

        // Regime = -1
        31'b01???_?????_?????_?????_?????_?????_?: begin
            ra_comb    = -1;
            exp_comb   = flp_a[28:26];
            fract_1a   = flp_a[25:0];
            fract_comb = {1'b1, fract_1a};
        end

        // Regime = -2
        31'b001??_?????_?????_?????_?????_?????_?: begin
            ra_comb    = -2;
            exp_comb   = flp_a[27:25];
            fract_1a   = {1'b0, flp_a[24:0]};
            fract_comb = {1'b1, fract_1a[24:0], 1'b0};
        end

        // Regime = -3
        31'b0001?_?????_?????_?????_?????_?????_?: begin
            ra_comb    = -3;
            exp_comb   = flp_a[26:24];
            fract_1a   = {2'b00, flp_a[23:0]};
            fract_comb = {1'b1, fract_1a[23:0], 2'b00};
        end

        // Regime = -4
        31'b00001_?????_?????_?????_?????_?????_?: begin
            ra_comb    = -4;
            exp_comb   = flp_a[25:23];
            fract_1a   = {3'b000, flp_a[22:0]};
            fract_comb = {1'b1, fract_1a[22:0], 3'b000};
        end

        // Regime = -5
        31'b00000_1????_?????_?????_?????_?????_?: begin
            ra_comb    = -5;
            exp_comb   = flp_a[24:22];
            fract_1a   = {4'b0000, flp_a[21:0]};
            fract_comb = {1'b1, fract_1a[21:0], 4'b0000};
        end

        // k=-5, no terminator (minpos family)
        31'b00000_0????_?????_?????_?????_?????_?: begin
            ra_comb    = -5;
            exp_comb   = 3'b000;
            fract_comb = 27'b100_0000_0000_0000_0000_0000_0000;
        end

        default: begin
            ra_comb    = 0;
            exp_comb   = 3'b000;
            fract_comb = 27'b0;
        end

    endcase
end

// ─── Pipeline register (Stage 1 output) ───────────────────────────────────────
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_out <= 1'b0;
        ra_o      <= 32'b0;
        exp_a     <= 3'b0;
        fract_a   <= 27'b0;
    end else begin
        valid_out <= valid_in;
        ra_o      <= ra_comb;
        exp_a     <= exp_comb;
        fract_a   <= fract_comb;
    end
end
endmodule

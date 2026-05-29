// =============================================================================
// de10_posit_fft8_top.v  (v7)
//
// Changes from v6:
//   - Removed unused ports: KEY[3], SW[9:6], LEDR[9:4]
//   - Only pins actually used in logic are declared
//
// UART:
//   GPIO[0] = PIN_W15  uart_rxd  (connect to CP2102 TX)
//   GPIO[1] = PIN_AK2  uart_txd  (connect to CP2102 RX)
//
// Controls:
//   KEY[0]  Reset (active low)
//   KEY[1]  Start FFT   — press when LEDR[0] is ON
//   KEY[2]  Send result — press when LEDR[2] is ON
//
// LEDs:
//   LEDR[0]  Frame received, waiting for KEY[1]
//   LEDR[1]  FFT running
//   LEDR[2]  Results ready, waiting for KEY[2]
//   LEDR[3]  UART TX busy (transmitting to PC)
//
// HEX display (normal mode, SW[5]=0):
//   HEX5–2  blank
//   HEX1    dominant bin number (1–4)
//   HEX0    blank
//
// HEX display (browse mode, SW[5]=1):
//   HEX5    'H' = upper half [31:16],  'L' = lower half [15:0]  (SW[4])
//   HEX4    bin index 0–7  (SW[2:0])
//   HEX3–0  4 hex digits of selected half-word
//
// Browse switches:
//   SW[5]   browse mode enable
//   SW[4]   0 = upper half [31:16],  1 = lower half [15:0]
//   SW[3]   0 = real part,           1 = imaginary part
//   SW[2:0] bin select 0–7
// =============================================================================

module de10_posit_fft8_top (
    input  wire        CLOCK_50,
    input  wire [2:0]  KEY,          // KEY[0]=reset  KEY[1]=start FFT  KEY[2]=send
    input  wire [5:0]  SW,           // SW[5:0] only — SW[9:6] unused, not declared
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5,
    output wire [3:0]  LEDR,         // LEDR[3:0] only — LEDR[9:4] unused, not declared
    input  wire        uart_rxd,     // GPIO[0] = PIN_W15
    output wire        uart_txd      // GPIO[1] = PIN_AK2
);

// Clock divider: 50 MHz → 25 MHz (period = 40 ns, plenty of margin)
reg clk_div;
always @(posedge CLOCK_50) begin
    clk_div <= ~clk_div;
end

wire clk = clk_div;   // 25 MHz
wire rst = ~KEY[0];

    // =========================================================================
    // 1. KEY debounce — KEY[1] (start FFT) and KEY[2] (send results)
    //    Active-low buttons: pressed = LOW, released = HIGH.
    //    We detect the falling edge (HIGH→LOW transition of the stable signal).
    // =========================================================================
    reg [19:0] deb1_cnt, deb2_cnt;
    reg        key1_stable, key2_stable;
    reg        key1_prev,   key2_prev;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            deb1_cnt   <= 20'd0; key1_stable <= 1'b1;
            deb2_cnt   <= 20'd0; key2_stable <= 1'b1;
            key1_prev  <= 1'b1;  key2_prev   <= 1'b1;
        end else begin
            // KEY[1] debounce
            if (KEY[1] != key1_stable) begin
                deb1_cnt <= deb1_cnt + 20'd1;
                if (&deb1_cnt) begin          // all bits set = 2^20 cycles ≈ 26 ms @ 40 MHz
                    key1_stable <= KEY[1];
                    deb1_cnt    <= 20'd0;
                end
            end else
                deb1_cnt <= 20'd0;

            // KEY[2] debounce
            if (KEY[2] != key2_stable) begin
                deb2_cnt <= deb2_cnt + 20'd1;
                if (&deb2_cnt) begin
                    key2_stable <= KEY[2];
                    deb2_cnt    <= 20'd0;
                end
            end else
                deb2_cnt <= 20'd0;

            key1_prev <= key1_stable;
            key2_prev <= key2_stable;
        end
    end

    // Falling edge of stable signal = button pressed (active-low)
    wire key1_press = key1_prev & ~key1_stable;
    wire key2_press = key2_prev & ~key2_stable;

    // =========================================================================
    // 2. UART RX — receives one frame: 0xAA header + 8×posit32 samples
    // =========================================================================
    wire        frame_valid;
    wire [31:0] br0_r, br1_r, br2_r, br3_r;
    wire [31:0] br4_r, br5_r, br6_r, br7_r;

    uart_rx rx_inst (
        .clk        (clk),
        .rst        (rst),
        .rxd        (uart_rxd),
        .frame_valid(frame_valid),
        .br0_r(br0_r), .br1_r(br1_r), .br2_r(br2_r), .br3_r(br3_r),
        .br4_r(br4_r), .br5_r(br5_r), .br6_r(br6_r), .br7_r(br7_r)
    );

    // =========================================================================
    // 3. Input latch — holds received samples stable for FFT
    //    Updates whenever a new valid frame arrives (even in FRAME_READY state)
    // =========================================================================
    reg [31:0] lat_r [0:7];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lat_r[0]<=32'd0; lat_r[1]<=32'd0;
            lat_r[2]<=32'd0; lat_r[3]<=32'd0;
            lat_r[4]<=32'd0; lat_r[5]<=32'd0;
            lat_r[6]<=32'd0; lat_r[7]<=32'd0;
        end else if (frame_valid) begin
            lat_r[0]<=br0_r; lat_r[1]<=br1_r;
            lat_r[2]<=br2_r; lat_r[3]<=br3_r;
            lat_r[4]<=br4_r; lat_r[5]<=br5_r;
            lat_r[6]<=br6_r; lat_r[7]<=br7_r;
        end
    end

    // =========================================================================
    // 4. FFT core — posit_fft8_serial_tm
    //    All imaginary inputs = 0 (real-valued audio samples)
    // =========================================================================
    reg         fft_start;
    wire        fft_done;
    wire [31:0] Xr [0:7];
    wire [31:0] Xi [0:7];

    posit_fft8_serial_tm fft_inst (
        .clk(clk), .rst(rst), .start(fft_start),
        .br0_r(lat_r[0]), .br0_i(32'h0),
        .br1_r(lat_r[1]), .br1_i(32'h0),
        .br2_r(lat_r[2]), .br2_i(32'h0),
        .br3_r(lat_r[3]), .br3_i(32'h0),
        .br4_r(lat_r[4]), .br4_i(32'h0),
        .br5_r(lat_r[5]), .br5_i(32'h0),
        .br6_r(lat_r[6]), .br6_i(32'h0),
        .br7_r(lat_r[7]), .br7_i(32'h0),
        .Xr0(Xr[0]), .Xi0(Xi[0]),
        .Xr1(Xr[1]), .Xi1(Xi[1]),
        .Xr2(Xr[2]), .Xi2(Xi[2]),
        .Xr3(Xr[3]), .Xi3(Xi[3]),
        .Xr4(Xr[4]), .Xi4(Xi[4]),
        .Xr5(Xr[5]), .Xi5(Xi[5]),
        .Xr6(Xr[6]), .Xi6(Xi[6]),
        .Xr7(Xr[7]), .Xi7(Xi[7]),
        .done(fft_done)
    );

    // =========================================================================
    // 5. FFT output capture registers
    // =========================================================================
    reg [31:0] out_r [0:7];
    reg [31:0] out_i [0:7];

    // =========================================================================
    // 6. Control FSM
    //
    //   S_IDLE           : waiting for frame_valid pulse from uart_rx
    //   S_FRAME_READY    : samples latched, LEDR[0] ON — waiting for KEY[1]
    //   S_FFT_RUN        : FFT running, LEDR[1] ON — waiting for fft_done
    //   S_RESULTS_READY  : outputs captured, LEDR[2] ON — waiting for KEY[2]
    //   S_TX             : transmitting, LEDR[3] ON — waiting for ~tx_busy
    //
    // =========================================================================
    localparam S_IDLE          = 3'd0,
               S_FRAME_READY   = 3'd1,
               S_FFT_RUN       = 3'd2,
               S_RESULTS_READY = 3'd3,
               S_TX            = 3'd4;

    reg [2:0] state;
    reg       tx_trigger;
    wire      tx_busy;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;
            fft_start  <= 1'b0;
            tx_trigger <= 1'b0;
            out_r[0]<=32'd0; out_r[1]<=32'd0;
            out_r[2]<=32'd0; out_r[3]<=32'd0;
            out_r[4]<=32'd0; out_r[5]<=32'd0;
            out_r[6]<=32'd0; out_r[7]<=32'd0;
            out_i[0]<=32'd0; out_i[1]<=32'd0;
            out_i[2]<=32'd0; out_i[3]<=32'd0;
            out_i[4]<=32'd0; out_i[5]<=32'd0;
            out_i[6]<=32'd0; out_i[7]<=32'd0;
        end else begin
            fft_start  <= 1'b0;
            tx_trigger <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (frame_valid)
                        state <= S_FRAME_READY;
                end

                S_FRAME_READY: begin
                    // New frame arriving here updates lat_r automatically.
                    // Wait for user to press KEY[1].
                    if (key1_press) begin
                        fft_start <= 1'b1;
                        state     <= S_FFT_RUN;
                    end
                end

                S_FFT_RUN: begin
                    if (fft_done) begin
                        out_r[0]<=Xr[0]; out_i[0]<=Xi[0];
                        out_r[1]<=Xr[1]; out_i[1]<=Xi[1];
                        out_r[2]<=Xr[2]; out_i[2]<=Xi[2];
                        out_r[3]<=Xr[3]; out_i[3]<=Xi[3];
                        out_r[4]<=Xr[4]; out_i[4]<=Xi[4];
                        out_r[5]<=Xr[5]; out_i[5]<=Xi[5];
                        out_r[6]<=Xr[6]; out_i[6]<=Xi[6];
                        out_r[7]<=Xr[7]; out_i[7]<=Xi[7];
                        state <= S_RESULTS_READY;
                    end
                end

                S_RESULTS_READY: begin
                    // Browse HEX display while waiting.
                    // KEY[2] fires transmission.
                    if (key2_press) begin
                        tx_trigger <= 1'b1;
                        state      <= S_TX;
                    end
                end

                S_TX: begin
                    // tx_trigger is a one-cycle pulse — uart_tx latches it.
                    // Wait until TX completes then go back to IDLE.
                    if (!tx_busy && !tx_trigger)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // LED indicators — directly decode FSM state
    assign LEDR[0] = (state == S_FRAME_READY);   // input ready, press KEY[1]
    assign LEDR[1] = (state == S_FFT_RUN);        // FFT running
    assign LEDR[2] = (state == S_RESULTS_READY);  // results ready, press KEY[2]
    assign LEDR[3] = (state == S_TX) | tx_busy;   // transmitting

    // =========================================================================
    // 7. UART TX — sends 0xBB header + 16×posit32 words (real + imag pairs)
    // =========================================================================
    uart_tx tx_inst (
        .clk    (clk),
        .rst    (rst),
        .start  (tx_trigger),
        .X0r(out_r[0]), .X0i(out_i[0]),
        .X1r(out_r[1]), .X1i(out_i[1]),
        .X2r(out_r[2]), .X2i(out_i[2]),
        .X3r(out_r[3]), .X3i(out_i[3]),
        .X4r(out_r[4]), .X4i(out_i[4]),
        .X5r(out_r[5]), .X5i(out_i[5]),
        .X6r(out_r[6]), .X6i(out_i[6]),
        .X7r(out_r[7]), .X7i(out_i[7]),
        .txd    (uart_txd),
        .tx_busy(tx_busy)
    );

    // =========================================================================
    // 8. Dominant bin detection
    //    Posit magnitude proxy: max(|real|, |imag|) — works because posit
    //    is a monotonic encoding (larger magnitude = larger unsigned value).
    //    DC bin (0) and mirror bins (5–7) ignored; check bins 1–4 only.
    // =========================================================================
    wire [31:0] pabs_r [0:7];
    wire [31:0] pabs_i [0:7];

    genvar gk;
    generate
        for (gk = 0; gk < 8; gk = gk + 1) begin : pabs
            assign pabs_r[gk] = out_r[gk][31] ? (~out_r[gk] + 1'b1) : out_r[gk];
            assign pabs_i[gk] = out_i[gk][31] ? (~out_i[gk] + 1'b1) : out_i[gk];
        end
    endgenerate

    // Magnitude proxy per bin (max of |real|, |imag|)
    wire [31:0] mp1 = (pabs_r[1] >= pabs_i[1]) ? pabs_r[1] : pabs_i[1];
    wire [31:0] mp2 = (pabs_r[2] >= pabs_i[2]) ? pabs_r[2] : pabs_i[2];
    wire [31:0] mp3 = (pabs_r[3] >= pabs_i[3]) ? pabs_r[3] : pabs_i[3];
    wire [31:0] mp4 = (pabs_r[4] >= pabs_i[4]) ? pabs_r[4] : pabs_i[4];

    // Priority encoder: find bin with largest magnitude
    reg [2:0] dom_bin;
    always @(*) begin
        if      (mp1 >= mp2 && mp1 >= mp3 && mp1 >= mp4) dom_bin = 3'd1;
        else if (mp2 >= mp3 && mp2 >= mp4)               dom_bin = 3'd2;
        else if (mp3 >= mp4)                             dom_bin = 3'd3;
        else                                             dom_bin = 3'd4;
    end

    // =========================================================================
    // 9. Browse mode data mux
    //    SW[5] = browse enable
    //    SW[4] = 0 → upper half [31:16],  1 → lower half [15:0]
    //    SW[3] = 0 → real,  1 → imaginary
    //    SW[2:0] = bin select 0–7
    // =========================================================================
    reg [31:0] sel32;
    always @(*) begin
        case (SW[2:0])
            3'd0: sel32 = SW[3] ? out_i[0] : out_r[0];
            3'd1: sel32 = SW[3] ? out_i[1] : out_r[1];
            3'd2: sel32 = SW[3] ? out_i[2] : out_r[2];
            3'd3: sel32 = SW[3] ? out_i[3] : out_r[3];
            3'd4: sel32 = SW[3] ? out_i[4] : out_r[4];
            3'd5: sel32 = SW[3] ? out_i[5] : out_r[5];
            3'd6: sel32 = SW[3] ? out_i[6] : out_r[6];
            3'd7: sel32 = SW[3] ? out_i[7] : out_r[7];
            default: sel32 = 32'b0;
        endcase
    end

    wire [15:0] disp16 = SW[4] ? sel32[15:0] : sel32[31:16];

    // =========================================================================
    // 10. 7-segment display
    // =========================================================================
    wire [6:0] seg_H     = 7'b0001001;   // 'H'
    wire [6:0] seg_L     = 7'b1000111;   // 'L'
    wire [6:0] seg_blank = 7'b1111111;   // all segments off

    // Browse mode hex digits
    wire [6:0] brow_h4; hex7seg bh4 (.val({1'b0, SW[2:0]}),  .seg(brow_h4));
    wire [6:0] brow_h3; hex7seg bh3 (.val(disp16[15:12]),     .seg(brow_h3));
    wire [6:0] brow_h2; hex7seg bh2 (.val(disp16[11: 8]),     .seg(brow_h2));
    wire [6:0] brow_h1; hex7seg bh1 (.val(disp16[ 7: 4]),     .seg(brow_h1));
    wire [6:0] brow_h0; hex7seg bh0 (.val(disp16[ 3: 0]),     .seg(brow_h0));

    // Normal mode: dominant bin number on HEX1
    // dom_bin is 1–4, display it as a decimal digit (same encoding as hex)
    wire [6:0] bin_seg;  hex7seg binseg (.val({1'b0, dom_bin}), .seg(bin_seg));

    // HEX mux
    // Browse mode  (SW[5]=1): HEX5='H'/'L'  HEX4=bin  HEX3-0=hex data
    // Normal mode  (SW[5]=0): HEX5-2=blank  HEX1=dom bin  HEX0=blank
    assign HEX5 = SW[5] ? (SW[4] ? seg_L : seg_H) : seg_blank;
    assign HEX4 = SW[5] ? brow_h4                 : seg_blank;
    assign HEX3 = SW[5] ? brow_h3                 : seg_blank;
    assign HEX2 = SW[5] ? brow_h2                 : seg_blank;
    assign HEX1 = SW[5] ? brow_h1                 : bin_seg;
    assign HEX0 = SW[5] ? brow_h0                 : seg_blank;

endmodule



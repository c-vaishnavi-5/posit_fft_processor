// =============================================================================
// uart_rx.v
// Receives one frame: 0xAA header + 8 x posit32 samples (33 bytes total)
// 50 MHz clock, 115200 baud
// =============================================================================
module uart_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire        rxd,
    output reg         frame_valid,
    output reg  [31:0] br0_r, br1_r, br2_r, br3_r,
    output reg  [31:0] br4_r, br5_r, br6_r, br7_r
);

localparam BAUD_DIV  = 217;   // 25 MHz / 115200
localparam HALF_BAUD = 108;   // floor(217/2)

    // FSM states
    localparam S_IDLE     = 2'd0;
    localparam S_START    = 2'd1;
    localparam S_DATA     = 2'd2;
    localparam S_STOP     = 2'd3;

    // -------------------------------------------------------------------------
    // 1. Synchronise RXD to clock domain (2-FF)
    // -------------------------------------------------------------------------
    reg rxd_s0, rxd_s1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin rxd_s0 <= 1'b1; rxd_s1 <= 1'b1; end
        else     begin rxd_s0 <= rxd;  rxd_s1 <= rxd_s0; end
    end

    // -------------------------------------------------------------------------
    // 2. UART byte receiver
    // -------------------------------------------------------------------------
    reg [1:0]  state;
    reg [15:0] baud_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift_reg;
    reg        byte_valid;
    reg [7:0]  byte_out;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;
            baud_cnt   <= 16'd0;
            bit_idx    <= 3'd0;
            shift_reg  <= 8'd0;
            byte_valid <= 1'b0;
            byte_out   <= 8'd0;
        end else begin
            byte_valid <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (rxd_s1 == 1'b0) begin   // falling edge = start bit
                        baud_cnt <= 16'd1;
                        state    <= S_START;
                    end
                end

                S_START: begin
                    if (baud_cnt == HALF_BAUD) begin  // sample mid start bit
                        if (rxd_s1 == 1'b0) begin     // still low -> valid start
                            baud_cnt <= 16'd1;
                            bit_idx  <= 3'd0;
                            state    <= S_DATA;
                        end else begin                 // glitch -> back to idle
                            state <= S_IDLE;
                        end
                    end else
                        baud_cnt <= baud_cnt + 16'd1;
                end

                S_DATA: begin
                    if (baud_cnt == BAUD_DIV) begin
                        baud_cnt          <= 16'd1;
                        shift_reg         <= {rxd_s1, shift_reg[7:1]};  // LSB first
                        if (bit_idx == 3'd7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 3'd1;
                    end else
                        baud_cnt <= baud_cnt + 16'd1;
                end

                S_STOP: begin
                    if (baud_cnt == BAUD_DIV) begin
                        baud_cnt   <= 16'd0;
                        byte_valid <= 1'b1;
                        byte_out   <= shift_reg;
                        state      <= S_IDLE;
                    end else
                        baud_cnt <= baud_cnt + 16'd1;
                end

            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 3. Frame assembler
    //    Frame = 0xAA + 8 x 4 bytes = 33 bytes total
    //    Byte order: MSB first for each 32-bit sample
    // -------------------------------------------------------------------------
    localparam FRAME_BYTES = 33;

    reg [7:0]  frame_buf [0:32];
    reg [5:0]  byte_cnt;
    reg        in_frame;

    integer k;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            byte_cnt    <= 6'd0;
            in_frame    <= 1'b0;
            frame_valid <= 1'b0;
            br0_r <= 32'd0; br1_r <= 32'd0;
            br2_r <= 32'd0; br3_r <= 32'd0;
            br4_r <= 32'd0; br5_r <= 32'd0;
            br6_r <= 32'd0; br7_r <= 32'd0;
            for (k = 0; k < FRAME_BYTES; k = k + 1)
                frame_buf[k] <= 8'd0;
        end else begin
            frame_valid <= 1'b0;

            if (byte_valid) begin
                if (!in_frame) begin
                    // Wait for 0xAA header
                    if (byte_out == 8'hAA) begin
                        in_frame <= 1'b1;
                        byte_cnt <= 6'd1;
                        frame_buf[0] <= 8'hAA;
                    end
                end else begin
                    frame_buf[byte_cnt] <= byte_out;
                    if (byte_cnt == FRAME_BYTES - 1) begin
                        // Full frame received — unpack
                        in_frame    <= 1'b0;
                        byte_cnt    <= 6'd0;
                        frame_valid <= 1'b1;
br0_r <= {frame_buf[1],  frame_buf[2],  frame_buf[3],  frame_buf[4]};   // sample 0
br1_r <= {frame_buf[17], frame_buf[18], frame_buf[19], frame_buf[20]};  // sample 4
br2_r <= {frame_buf[9],  frame_buf[10], frame_buf[11], frame_buf[12]};  // sample 2
br3_r <= {frame_buf[25], frame_buf[26], frame_buf[27], frame_buf[28]};  // sample 6
br4_r <= {frame_buf[5],  frame_buf[6],  frame_buf[7],  frame_buf[8]};   // sample 1
br5_r <= {frame_buf[21], frame_buf[22], frame_buf[23], frame_buf[24]};  // sample 5
br6_r <= {frame_buf[13], frame_buf[14], frame_buf[15], frame_buf[16]};  // sample 3
br7_r <= {frame_buf[29], frame_buf[30], frame_buf[31], byte_out};       // sample 7
                    end else
                        byte_cnt <= byte_cnt + 6'd1;
                end
            end
        end
    end

endmodule

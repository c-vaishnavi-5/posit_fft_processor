// =============================================================================
// uart_tx.v
// Transmits one frame: 0xBB header + 8 x (real + imag) posit32 = 65 bytes
// 50 MHz clock, 115200 baud
// =============================================================================
module uart_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] X0r, X0i,
    input  wire [31:0] X1r, X1i,
    input  wire [31:0] X2r, X2i,
    input  wire [31:0] X3r, X3i,
    input  wire [31:0] X4r, X4i,
    input  wire [31:0] X5r, X5i,
    input  wire [31:0] X6r, X6i,
    input  wire [31:0] X7r, X7i,
    output reg         txd,
    output reg         tx_busy
);

localparam BAUD_DIV  = 217;   // 25 MHz / 115200

    // Frame: 1 header + 8*8 data bytes = 65 bytes total
    localparam FRAME_BYTES = 65;

    // -------------------------------------------------------------------------
    // 1. Build transmit buffer when start pulse arrives
    // -------------------------------------------------------------------------
    reg [7:0] tx_buf [0:64];
    reg [6:0] byte_idx;    // which byte we are sending
    reg [3:0] bit_idx;     // which bit within the byte (0=start, 1-8=data, 9=stop)
    reg [15:0] baud_cnt;

    // FSM
    localparam S_IDLE = 1'b0;
    localparam S_SEND = 1'b1;
    reg state;

    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            txd      <= 1'b1;
            tx_busy  <= 1'b0;
            state    <= S_IDLE;
            byte_idx <= 7'd0;
            bit_idx  <= 4'd0;
            baud_cnt <= 16'd0;
            for (i = 0; i < FRAME_BYTES; i = i + 1)
                tx_buf[i] <= 8'd0;
        end else begin
            case (state)

                S_IDLE: begin
                    txd     <= 1'b1;
                    tx_busy <= 1'b0;
                    if (start) begin
                        // Load frame buffer
                        tx_buf[0]  <= 8'hBB;   // header
                        // Sample 0
                        tx_buf[1]  <= X0r[31:24]; tx_buf[2]  <= X0r[23:16];
                        tx_buf[3]  <= X0r[15:8];  tx_buf[4]  <= X0r[7:0];
                        tx_buf[5]  <= X0i[31:24]; tx_buf[6]  <= X0i[23:16];
                        tx_buf[7]  <= X0i[15:8];  tx_buf[8]  <= X0i[7:0];
                        // Sample 1
                        tx_buf[9]  <= X1r[31:24]; tx_buf[10] <= X1r[23:16];
                        tx_buf[11] <= X1r[15:8];  tx_buf[12] <= X1r[7:0];
                        tx_buf[13] <= X1i[31:24]; tx_buf[14] <= X1i[23:16];
                        tx_buf[15] <= X1i[15:8];  tx_buf[16] <= X1i[7:0];
                        // Sample 2
                        tx_buf[17] <= X2r[31:24]; tx_buf[18] <= X2r[23:16];
                        tx_buf[19] <= X2r[15:8];  tx_buf[20] <= X2r[7:0];
                        tx_buf[21] <= X2i[31:24]; tx_buf[22] <= X2i[23:16];
                        tx_buf[23] <= X2i[15:8];  tx_buf[24] <= X2i[7:0];
                        // Sample 3
                        tx_buf[25] <= X3r[31:24]; tx_buf[26] <= X3r[23:16];
                        tx_buf[27] <= X3r[15:8];  tx_buf[28] <= X3r[7:0];
                        tx_buf[29] <= X3i[31:24]; tx_buf[30] <= X3i[23:16];
                        tx_buf[31] <= X3i[15:8];  tx_buf[32] <= X3i[7:0];
                        // Sample 4
                        tx_buf[33] <= X4r[31:24]; tx_buf[34] <= X4r[23:16];
                        tx_buf[35] <= X4r[15:8];  tx_buf[36] <= X4r[7:0];
                        tx_buf[37] <= X4i[31:24]; tx_buf[38] <= X4i[23:16];
                        tx_buf[39] <= X4i[15:8];  tx_buf[40] <= X4i[7:0];
                        // Sample 5
                        tx_buf[41] <= X5r[31:24]; tx_buf[42] <= X5r[23:16];
                        tx_buf[43] <= X5r[15:8];  tx_buf[44] <= X5r[7:0];
                        tx_buf[45] <= X5i[31:24]; tx_buf[46] <= X5i[23:16];
                        tx_buf[47] <= X5i[15:8];  tx_buf[48] <= X5i[7:0];
                        // Sample 6
                        tx_buf[49] <= X6r[31:24]; tx_buf[50] <= X6r[23:16];
                        tx_buf[51] <= X6r[15:8];  tx_buf[52] <= X6r[7:0];
                        tx_buf[53] <= X6i[31:24]; tx_buf[54] <= X6i[23:16];
                        tx_buf[55] <= X6i[15:8];  tx_buf[56] <= X6i[7:0];
                        // Sample 7
                        tx_buf[57] <= X7r[31:24]; tx_buf[58] <= X7r[23:16];
                        tx_buf[59] <= X7r[15:8];  tx_buf[60] <= X7r[7:0];
                        tx_buf[61] <= X7i[31:24]; tx_buf[62] <= X7i[23:16];
                        tx_buf[63] <= X7i[15:8];  tx_buf[64] <= X7i[7:0];

                        byte_idx <= 7'd0;
                        bit_idx  <= 4'd0;
                        baud_cnt <= 16'd0;
                        tx_busy  <= 1'b1;
                        state    <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= 16'd0;
                        case (bit_idx)
                            4'd0: txd <= 1'b0;   // start bit
                            4'd1: txd <= tx_buf[byte_idx][0];
                            4'd2: txd <= tx_buf[byte_idx][1];
                            4'd3: txd <= tx_buf[byte_idx][2];
                            4'd4: txd <= tx_buf[byte_idx][3];
                            4'd5: txd <= tx_buf[byte_idx][4];
                            4'd6: txd <= tx_buf[byte_idx][5];
                            4'd7: txd <= tx_buf[byte_idx][6];
                            4'd8: txd <= tx_buf[byte_idx][7];
                            4'd9: begin           // stop bit
                                txd <= 1'b1;
                                if (byte_idx == FRAME_BYTES - 1) begin
                                    // Done
                                    tx_busy <= 1'b0;
                                    state   <= S_IDLE;
                                end else begin
                                    byte_idx <= byte_idx + 7'd1;
                                end
                            end
                            default: txd <= 1'b1;
                        endcase
                        if (bit_idx == 4'd9)
                            bit_idx <= 4'd0;
                        else
                            bit_idx <= bit_idx + 4'd1;
                    end else
                        baud_cnt <= baud_cnt + 16'd1;
                end

            endcase
        end
    end

endmodule

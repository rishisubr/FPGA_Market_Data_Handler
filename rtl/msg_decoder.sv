/* verilator lint_off IMPORTSTAR */
import itch_lite_pkg::*;
/* verilator lint_on IMPORTSTAR */

module msg_decoder (
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream Slave
    input  logic [63:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,

    // Control input and outputs
    input  logic        m_axis_tready,  // downstream readiness
    output logic        msg_start,
    output logic        header_valid,
    output logic        msg_done,
    output logic        framing_error,

    // Decoded event output (plain logic for Yosys compatibility)
    output logic [287:0] order_event_raw
);

    // Internal typed signal; assign to flat output at boundary
    order_event_t order_event;
    assign order_event_raw = order_event;

    // ------------------------------------------------------------------------
    // Internal Registers
    // ------------------------------------------------------------------------
    logic [7:0]  byte_cnt;
    logic [63:0] prev_tdata;

    // ------------------------------------------------------------------------
    // AXI Helpers & 128-bit Sliding Window
    // ------------------------------------------------------------------------
    assign s_axis_tready = m_axis_tready && rst_n;

    logic [3:0] bytes_in_word;
    assign bytes_in_word = $countones(s_axis_tkeep);

    logic [8:0] total_bytes;
    assign total_bytes = byte_cnt + {5'b0, bytes_in_word};

    // Window: prev_tdata in [63:0], incoming tdata in [127:64]
    // byte 0 of the current word is at window[(byte_cnt_offset + 8)*8 +: 8]
    logic [127:0] window;
    assign window = {s_axis_tdata, prev_tdata};

    // ------------------------------------------------------------------------
    // Combinational Processes
    // ------------------------------------------------------------------------
    // Peek ahead at wire on first word, otherwise use latched msg_type
    msg_type_e active_msg_type;
    always_comb begin
        if (byte_cnt == 0 && total_bytes >= 1)
            active_msg_type = msg_type_e'(window[71:64]);
        else
            active_msg_type = order_event.msg_type;
    end
    
    // Message length lookup
    logic [7:0]  current_msg_len;
    always_comb begin
        case (active_msg_type)
            MSG_ADD:     current_msg_len = ADD_LEN;
            MSG_CANCEL:  current_msg_len = CANCEL_LEN;
            MSG_EXECUTE: current_msg_len = EXECUTE_LEN;
            default:     current_msg_len = '0;
        endcase
    end

    // Update for byte_cnt
    logic [8:0]  byte_cnt_next;
    assign byte_cnt_next = total_bytes - {1'b0, current_msg_len};

    // ------------------------------------------------------------------------
    // Error Handling
    // ------------------------------------------------------------------------
    logic framing_error_now;
    assign framing_error_now = s_axis_tvalid && s_axis_tready && s_axis_tlast 
                                && (total_bytes < {1'b0, current_msg_len});

    // ------------------------------------------------------------------------
    // Sequential Process
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt      <= '0;
            prev_tdata    <= '0;
            msg_start     <= '0;
            header_valid  <= '0;
            msg_done      <= '0;
            framing_error <= '0;
            order_event   <= '0;
        end else begin
            msg_start     <= '0;
            header_valid  <= '0;
            msg_done      <= '0;
            framing_error <= '0;
            if (msg_done) order_event <= '0;

            if (s_axis_tvalid && s_axis_tready) begin
                prev_tdata <= s_axis_tdata;

                // ------------------------------------------------------------
                // 1. Start pulse on first byte of new message
                // ------------------------------------------------------------
                if (byte_cnt == 0 && total_bytes >= 1)
                    msg_start <= 1'b1;

                // ------------------------------------------------------------
                // 2. Field extraction from sliding window
                //    Formula: window[((offset - byte_cnt + 8) * 8) +: width]
                //    The +8 accounts for prev_tdata occupying window[63:0];
                //    s_axis_tdata occupies window[127:64], so byte 0 of the
                //    current incoming word is window[64 +: 8] = tdata[7:0].
                // ------------------------------------------------------------

                // msg_type (offset 0, 8 bits)
                if (byte_cnt < 1 && total_bytes >= 1)
                    order_event.msg_type <= msg_type_e'(window[((0 - byte_cnt + 8) * 8) +: 8]);

                // stock_locate (offset 1, 16 bits)
                if (byte_cnt < 3 && total_bytes >= 3)
                    order_event.stock_locate <= bswap16(window[((1 - byte_cnt + 8) * 8) +: 16]);

                // tracking_number (offset 3, 16 bits)
                if (byte_cnt < 5 && total_bytes >= 5)
                    order_event.tracking_number <= bswap16(window[((3 - byte_cnt + 8) * 8) +: 16]);

                // timestamp (offset 5, 48 bits)
                if (byte_cnt < 11 && total_bytes >= 11)
                    order_event.timestamp <= bswap48(window[((5 - byte_cnt + 8) * 8) +: 48]);

                // order_ref (offset 11, 64 bits) — header complete when this lands
                if (byte_cnt < 19 && total_bytes >= 19) begin
                    order_event.order_ref <= bswap64(window[((11 - byte_cnt + 8) * 8) +: 64]);
                    header_valid          <= 1'b1;
                end

                // ------------------------------------------------------------
                // 3. Type-specific payload fields
                // ------------------------------------------------------------
                unique case (active_msg_type)
                    MSG_ADD: begin
                        // side (offset 19, 8 bits) — no swap needed for 1-byte field
                        if (byte_cnt < 20 && total_bytes >= 20)
                            order_event.payload.add.side <= side_e'(window[((19 - byte_cnt + 8) * 8) +: 8]);
                        // shares (offset 20, 32 bits)
                        if (byte_cnt < 24 && total_bytes >= 24)
                            order_event.payload.add.shares <= bswap32(window[((20 - byte_cnt + 8) * 8) +: 32]);
                        // symbol (offset 24, 64 bits) — skipped, not decoded
                        // price (offset 32, 32 bits)
                        if (byte_cnt < 36 && total_bytes >= 36)
                            order_event.payload.add.price <= bswap32(window[((32 - byte_cnt + 8) * 8) +: 32]);
                    end

                    MSG_CANCEL: begin
                        // cancelled_shares (offset 19, 32 bits)
                        if (byte_cnt < 23 && total_bytes >= 23)
                            order_event.payload.cancel.shares <= bswap32(window[((19 - byte_cnt + 8) * 8) +: 32]);
                    end

                    MSG_EXECUTE: begin
                        // executed_shares (offset 19, 32 bits)
                        if (byte_cnt < 23 && total_bytes >= 23)
                            order_event.payload.execute.shares <= bswap32(window[((19 - byte_cnt + 8) * 8) +: 32]);
                        // match_number (offset 23, 64 bits)
                        if (byte_cnt < 31 && total_bytes >= 31)
                            order_event.payload.execute.match <= bswap64(window[((23 - byte_cnt + 8) * 8) +: 64]);
                    end

                    default: ;
                endcase

                // ------------------------------------------------------------
                // 4. Message completion & packet boundary recovery
                // ------------------------------------------------------------
                if (current_msg_len != '0) begin
                    if (total_bytes >= {1'b0, current_msg_len}) begin
                        msg_done <= 1'b1;
                        // If tlast coincides with message boundary, reset cleanly;
                        // otherwise carry leftover bytes into the next cycle
                        byte_cnt <= s_axis_tlast ? '0 : byte_cnt_next[7:0];
                    end else begin
                        if (s_axis_tlast) begin
                            // Packet ended before message was complete — framing error
                            framing_error <= 1'b1;
                            byte_cnt      <= '0;
                        end else begin
                            byte_cnt <= total_bytes;
                        end
                    end
                end else if (!framing_error_now) begin
                    // Unknown message type — pulse done and reset
                    msg_done <= 1'b1;
                    byte_cnt <= '0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // SVA Assertions (formal verification only)
    // ------------------------------------------------------------------------
`ifdef FORMAL
    property p_byte_cnt_bounded;
        @(posedge clk) disable iff (!rst_n)
        (byte_cnt > 0) |-> (byte_cnt < current_msg_len);
    endproperty
    assert property (p_byte_cnt_bounded) else $error("byte_cnt exceeded valid message length");

    property p_msg_done_one_cycle;
        @(posedge clk) disable iff (!rst_n)
        msg_done |=> !msg_done;
    endproperty
    assert property (p_msg_done_one_cycle) else $error("msg_done held high 2+ cycles");

    property p_cnt_resets_after_done;
        @(posedge clk) disable iff (!rst_n)
        (msg_done && s_axis_tlast) |=> (byte_cnt == 0);
    endproperty
    assert property (p_cnt_resets_after_done) else $error("byte_cnt did not reset after msg_done+tlast");

    property p_legal_msg_type;
        @(posedge clk) disable iff (!rst_n)
        (byte_cnt > 0) |-> (order_event.msg_type == MSG_ADD ||
                            order_event.msg_type == MSG_CANCEL ||
                            order_event.msg_type == MSG_EXECUTE);
    endproperty
    assert property (p_legal_msg_type) else $error("illegal msg_type mid-message");
`endif

endmodule
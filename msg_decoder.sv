/* verilator lint_off IMPORTSTAR */
import itch_lite_pkg::*;
/* verilator lint_on IMPORTSTAR */

module msg_decoder (

    input logic         clk,
    input logic         rst_n,
    input logic         in_valid,
    input logic [7:0]   in_byte,

    // Streaming decoded outputs as soon as their byte chunk completes
    output logic        msg_start,      // high for 1 cycle when byte 0 arrives
    output logic [7:0]  msg_type_raw,       // latched message type

    output logic        header_valid,   // high for 1 cycle when bytes 1-18 complete
    output logic[15:0]  stock_locate,
    output logic[15:0]  tracking_number,
    output logic[47:0]  timestamp,
    output logic[63:0]  order_ref,

    output [95:0]       payload_raw,
    output logic        msg_done        // high for 1 cycle when the full message completes
);

    // Custom type internal signals – connect to outputs
    msg_type_e  msg_type;
    payload_u   payload;
    
    assign msg_type_raw = msg_type;
    assign payload_raw = payload;

    // Byte position tracker within the current message
    logic [7:0] byte_cnt;
    logic [7:0] current_msg_len;

    // ------------------------------------------------------------------------
    // Message length lookup
    // ------------------------------------------------------------------------
    always_comb begin
        case (msg_type)
            MSG_ADD:        current_msg_len = ADD_LEN;
            MSG_CANCEL:     current_msg_len = CANCEL_LEN;
            MSG_EXECUTE:    current_msg_len = EXECUTE_LEN;
            default:        current_msg_len = '0; // unsupported message type
        endcase
    end

    // ------------------------------------------------------------------------
    // Header (bytes 1-18), payload (bytes 19+)
    //
    // Payload fields are assembled by shift-and-append: each new byte shifts 
    // the field left by 8 and appends the new byte at the bottom b/c wire is 
    // big-endian.
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt        <= '0;
            msg_type        <= msg_type_e'('0);
            msg_start       <= '0;
            stock_locate    <= '0;
            tracking_number <= '0;
            timestamp       <= '0;
            order_ref       <= '0;
            header_valid    <= '0;
            payload         <= '0;
            msg_done        <= '0;
        end else begin
            msg_start    <= '0;
            header_valid <= '0;
            msg_done     <= '0; // default pulse low

            if (in_valid) begin
                // Byte 0: message type start
                if (byte_cnt == 0) begin
                    msg_type  <= msg_type_e'(in_byte);
                    msg_start <= 1'b1;
                end

                // Bytes 1-18: common header – direct bit slicing
                if      (byte_cnt >= 1  && byte_cnt <= 2)  stock_locate[(2 - byte_cnt) * 8 +: 8]     <= in_byte;
                else if (byte_cnt >= 3  && byte_cnt <= 4)  tracking_number[(4 - byte_cnt) * 8 +: 8]  <= in_byte;
                else if (byte_cnt >= 5  && byte_cnt <= 10) timestamp[(10 - byte_cnt) * 8 +: 8]       <= in_byte;
                else if (byte_cnt >= 11 && byte_cnt <= 18) order_ref[(18 - byte_cnt) * 8 +: 8]       <= in_byte;

                // Byte 18: pulse header_valid
                if (byte_cnt == 18) begin
                    header_valid <= 1'b1;
                end

                // Type-specific payload assembly — shift-and-append per field
                unique case (msg_type)
                    MSG_ADD: begin
                        if (byte_cnt == 19)
                            payload.add.side <= side_e'(in_byte);
                        else if (byte_cnt >= 20 && byte_cnt <= 23)
                            payload.add.shares <= {payload.add.shares[23:0], in_byte};
                        // ignore the ASCII stock symbol (bytes 24-31)
                        else if (byte_cnt >= 32 && byte_cnt <= 35)
                            payload.add.price <= {payload.add.price[23:0], in_byte};
                    end

                    MSG_CANCEL: begin
                        if (byte_cnt >= 19 && byte_cnt <= 22)
                            payload.cancel.shares <= {payload.cancel.shares[23:0], in_byte};
                    end

                    MSG_EXECUTE: begin
                        if (byte_cnt >= 19 && byte_cnt <= 22)
                            payload.execute.shares <= {payload.execute.shares[23:0], in_byte};
                        else if (byte_cnt >= 23 && byte_cnt <= 30)
                            payload.execute.match <= {payload.execute.match[55:0], in_byte};
                    end

                    default: ;
                endcase

                // Completion check & counter wraparound
                // Normal finish or instant drop if unsuported message type (length == 0)
                if ((current_msg_len != '0 && byte_cnt == current_msg_len - 1) ||
                    (current_msg_len == '0 && byte_cnt > 0)) begin
                        msg_done <= 1'b1;
                        byte_cnt <= '0;
                end else begin
                    byte_cnt <= byte_cnt + 8'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Verification with assert statements - used with SymbiYosys
    // ------------------------------------------------------------------------

    `ifdef FORMAL
        // byte_cnt never runs past the current message's known length
        property p_byte_cnt_bounded;
            @(posedge clk) disable iff (!rst_n)
            (byte_cnt > 0) |-> (byte_cnt < current_msg_len);
        endproperty
        assert property (p_byte_cnt_bounded) else $error("byte_cnt exceeded valid message length or unhandled type");

        // msg_done pulses exactly one cycle, then drops
        property p_msg_done_one_cycle;
            @(posedge clk) disable iff (!rst_n)
            msg_done |=> !msg_done;
        endproperty
        assert property (p_msg_done_one_cycle) else $error("msg_done held high 2+ cycles");

        // byte_cnt resets to 0 the cycle after msg_done
        property p_cnt_resets_after_done;
            @(posedge clk) disable iff (!rst_n)
            msg_done |=> (byte_cnt == 0);
        endproperty
        assert property (p_cnt_resets_after_done) else $error("byte_cnt did not reset after msg_done");

        // msg_type only ever holds a legal value once a message has started
        property p_legal_msg_type;
            @(posedge clk) disable iff (!rst_n)
            (byte_cnt > 0) |-> (msg_type inside {MSG_ADD, MSG_CANCEL, MSG_EXECUTE});
        endproperty
        assert property (p_legal_msg_type) else $error("illegal msg_type mid-message");
    `endif

endmodule

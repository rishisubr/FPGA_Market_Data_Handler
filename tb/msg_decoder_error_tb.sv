/* verilator lint_off IMPORTSTAR */
import itch_lite_pkg::*; //[cite: 1]
/* verilator lint_on IMPORTSTAR */

module msg_decoder_error_tb;

    timeunit 1ns; timeprecision 1ps;

    // Clock and reset
    logic clk = 0;
    always #5 clk = ~clk;   // 10ns period = 100MHz

    logic rst_n;

    // DUT AXI-Stream Slave interface[cite: 2]
    logic [63:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic [7:0]  s_axis_tkeep;
    logic        s_axis_tlast;
    logic        s_axis_tready;

    // DUT Control & Status interface[cite: 2]
    logic        m_axis_tready;
    logic        msg_start;
    logic        header_valid;
    logic        msg_done;
    logic        framing_error;
    logic [287:0] order_event_raw; //[cite: 2]

    // Unpack raw vector to structured type[cite: 1, 2]
    order_event_t order_event;
    assign order_event = order_event_t'(order_event_raw);

    msg_decoder dut (.*); //[cite: 2]

    // Waveform dump
    initial begin
        $dumpfile("dump_error.vcd");
        $dumpvars(0, msg_decoder_error_tb);
    end

    // Module-scope static queue to prevent Icarus Verilog crashes[cite: 3]
    logic [7:0] tx_queue[$];

    // ---------------------------------------------------------------------
    // 64-Bit AXI-Stream Driver Task
    // ---------------------------------------------------------------------
    task automatic send_message(input logic set_tlast = 1'b1);
        while (tx_queue.size() > 0) begin
            logic [63:0] word_data = '0;
            logic [7:0]  word_keep = '0;
            int n = (tx_queue.size() >= 8) ? 8 : tx_queue.size();

            for (int i = 0; i < n; i++) begin
                word_data[i*8 +: 8] = tx_queue.pop_front();
                word_keep[i]        = 1'b1;
            end

            s_axis_tdata  <= word_data;
            s_axis_tkeep  <= word_keep;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= (tx_queue.size() == 0 && set_tlast) ? 1'b1 : 1'b0;

            do begin
                @(posedge clk);
            end while (!s_axis_tready); //[cite: 2]
        end

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        s_axis_tkeep  <= '0;
        s_axis_tdata  <= '0;
    endtask

    // ---------------------------------------------------------------------
    // Checking Helpers
    // ---------------------------------------------------------------------
    int errors = 0;

    task automatic check_flag(string test_name, logic actual, logic expected);
        if (actual !== expected) begin
            $display("FAIL [%s]: Flag = %0b, expected %0b", test_name, actual, expected);
            errors++;
        end else begin
            $display("PASS [%s]: Flag behaved as expected (%0b)", test_name, actual);
        end
    endtask

    // Test Vectors
    logic [7:0] cancel_msg [0:22] = '{
        8'h58,                                                  // msg_type 'X'[cite: 1, 4]
        8'h00, 8'h01,                                           // stock_locate = 1[cite: 4]             
        8'h00, 8'h01,                                           // tracking_number = 1[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC8,               // timestamp = 200[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, // order_ref = 1[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h1E                              // cancelled_shares = 30[cite: 4]
    };

    logic [7:0] execute_msg [0:30] = '{
        8'h45,                                                  // msg_type 'E'[cite: 1, 4]
        8'h00, 8'h01,                                           // stock_locate = 1[cite: 4]
        8'h00, 8'h01,                                           // tracking_number = 1[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h2C,               // timestamp = 300[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, // order_ref = 1[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h28,                             // executed_shares = 40[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h03, 8'hE8  // match_number = 1000[cite: 4]
    };

    initial begin
        rst_n         <= 0;
        s_axis_tvalid <= 0;
        s_axis_tdata  <= '0;
        s_axis_tkeep  <= '0;
        s_axis_tlast  <= 0;
        m_axis_tready <= 1;

        repeat (3) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);

        // Test 1: Truncated Packet (Framing Error)[cite: 2]
        $display("\n--- Test 1: Truncated Packet (Framing Error) ---");
        tx_queue = {};
        tx_queue.push_back(MSG_ADD); //[cite: 1]
        for (int i = 1; i < 16; i++) begin
            tx_queue.push_back(8'hAA);
        end
        
        send_message(1'b1);
        #1;

        check_flag("Truncated Packet -> framing_error asserted", framing_error, 1'b1); //[cite: 2]
        check_flag("Truncated Packet -> msg_done suppressed",    msg_done,      1'b0); //[cite: 2]
        @(posedge clk);

        // Test 2: Post-Framing Error Recovery
        $display("\n--- Test 2: Clean Recovery After Framing Error ---");
        tx_queue = {};
        for (int i = 0; i < 23; i++) tx_queue.push_back(cancel_msg[i]);
        
        send_message(1'b1);
        #1;

        check_flag("Post-Error Recovery -> framing_error is clear", framing_error, 1'b0); //[cite: 2]
        check_flag("Post-Error Recovery -> msg_done asserted",      msg_done,      1'b1); //[cite: 2]
        if (order_event.payload.cancel.shares !== 30) begin
            $display("FAIL [Post-Error Recovery]: Cancelled shares corrupted (%0d != 30)", order_event.payload.cancel.shares);
            errors++;
        end else begin
            $display("PASS [Post-Error Recovery]: Cancelled shares cleanly decoded (30)");
        end
        @(posedge clk);

        // Test 3: Unsupported Message Type Drop[cite: 2]
        $display("\n--- Test 3: Unsupported Message Type Drop ---");
        tx_queue = {};
        tx_queue.push_back(8'h5A); // Unknown tag 'Z'
        for (int i = 1; i < 8; i++) begin
            tx_queue.push_back(8'hBB);
        end
        
        send_message(1'b1);
        #1;

        check_flag("Unknown Msg Tag -> msg_done asserted (instant flush)", msg_done,      1'b1); //[cite: 2]
        check_flag("Unknown Msg Tag -> framing_error suppressed",          framing_error, 1'b0); //[cite: 2]
        @(posedge clk);

        // Test 4: Post-Flush Recovery
        $display("\n--- Test 4: Post-Flush Pipeline Recovery ---");
        tx_queue = {};
        for (int i = 0; i < 31; i++) tx_queue.push_back(execute_msg[i]);
        
        send_message(1'b1);
        #1;

        check_flag("Post-Flush Recovery -> msg_done asserted", msg_done, 1'b1); //[cite: 2]
        if (order_event.payload.execute.match !== 1000) begin
            $display("FAIL [Post-Flush Recovery]: Match ID corrupted (%0d != 1000)", order_event.payload.execute.match);
            errors++;
        end else begin
            $display("PASS [Post-Flush Recovery]: Match ID cleanly decoded (1000)");
        end
        @(posedge clk);

        $finish;
    end

    final begin
        if (errors == 0) $display("\n=== ALL ERROR & RECOVERY TESTS PASSED ===");
        else             $display("\n=== %0d ERROR CHECK(S) FAILED ===", errors);
    end

endmodule
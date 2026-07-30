/* verilator lint_off IMPORTSTAR */
import itch_lite_pkg::*; //[cite: 1]
/* verilator lint_on IMPORTSTAR */

module msg_decoder_tb;

    timeunit 1ns; timeprecision 1ps;

    // Clock and reset
    logic clk = 0;
    always #5 clk = ~clk;   // 10ns period = 100MHz

    logic rst_n;

    // DUT AXI-Stream Slave interface (matching msg_decoder.sv ports)[cite: 2]
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

    // Unpack raw vector to structured type defined in itch_lite_pkg[cite: 1, 2]
    order_event_t order_event;
    assign order_event = order_event_t'(order_event_raw);

    msg_decoder dut (.*); //[cite: 2]

    // Waveform dump
    initial begin
        $dumpfile("dump_directed.vcd");
        $dumpvars(0, msg_decoder_tb);
    end

    // Module-scope static queue to prevent Icarus Verilog automatic argument crashes[cite: 3]
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
    // Synchronization & Checking Helpers (with NBA race avoidance)
    // ---------------------------------------------------------------------
    int errors = 0;
    task automatic wait_and_check_done();
        #1; // Step past NBA region
        if (!msg_done) begin
            int timeout = 20;
            while (!msg_done && timeout > 0) begin
                @(posedge clk);
                #1;
                timeout--;
            end
        end
        if (!msg_done) begin
            $display("FAIL: msg_done did not pulse within timeout!");
            errors++;
        end
    endtask

    task automatic check(string field_name, logic [63:0] actual, logic [63:0] expected);
        if (actual !== expected) begin
            $display("FAIL: %s = %0d, expected %0d", field_name, actual, expected);
            errors++;
        end else begin
            $display("PASS: %s = %0d", field_name, actual);
        end
    endtask

    // Standard ITCH Directed Test Vectors[cite: 4]
    logic [7:0] add_msg [0:35] = '{
        8'h41,                                                  // msg_type 'A'[cite: 1, 4]
        8'h00, 8'h01,                                           // stock_locate = 1[cite: 4]
        8'h00, 8'h01,                                           // tracking_number = 1[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h64,               // timestamp = 100[cite: 4]
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, // order_ref = 1[cite: 4]
        8'h42,                                                  // side 'B' (buy)[cite: 1, 4]
        8'h00, 8'h00, 8'h00, 8'h64,                             // shares = 100[cite: 4]
        8'h41, 8'h41, 8'h50, 8'h4C, 8'h20, 8'h20, 8'h20, 8'h20, // symbol "AAPL    "[cite: 4]
        8'h00, 8'h07, 8'hA1, 8'h20                              // price = 500000[cite: 4]
    };

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

        // ---------------- Add Order ----------------
        $display("\n--- Sending Add Order ---");
        tx_queue = {};
        for (int i = 0; i < 36; i++) tx_queue.push_back(add_msg[i]);
        send_message(1'b1);
        wait_and_check_done();
        
        check("msg_type",        order_event.msg_type,          MSG_ADD); //[cite: 1]
        check("stock_locate",    order_event.stock_locate,      1);
        check("tracking_number", order_event.tracking_number,   1);
        check("timestamp",       order_event.timestamp,         100);
        check("order_ref",       order_event.order_ref,         1);
        check("side",            order_event.payload.add.side,   SIDE_BUY); //[cite: 1]
        check("shares",          order_event.payload.add.shares, 100);
        check("price",           order_event.payload.add.price,  500000);
        @(posedge clk);

        // ---------------- Order Cancel ----------------
        $display("\n--- Sending Cancel Order ---");
        tx_queue = {};
        for (int i = 0; i < 23; i++) tx_queue.push_back(cancel_msg[i]);
        send_message(1'b1);
        wait_and_check_done();
        
        check("msg_type",         order_event.msg_type,              MSG_CANCEL); //[cite: 1]
        check("timestamp",        order_event.timestamp,             200);
        check("order_ref",        order_event.order_ref,             1);
        check("cancelled_shares", order_event.payload.cancel.shares, 30);
        @(posedge clk);

        // ---------------- Order Executed ----------------
        $display("\n--- Sending Execute Order ---");
        tx_queue = {};
        for (int i = 0; i < 31; i++) tx_queue.push_back(execute_msg[i]);
        send_message(1'b1);
        wait_and_check_done();
        
        check("msg_type",        order_event.msg_type,               MSG_EXECUTE); //[cite: 1]
        check("timestamp",       order_event.timestamp,              300);
        check("order_ref",       order_event.order_ref,              1);
        check("executed_shares", order_event.payload.execute.shares, 40);
        check("match_number",    order_event.payload.execute.match,  1000);
        @(posedge clk);

        $finish;
    end

    final begin
        if (errors == 0) $display("\n=== ALL DIRECTED TESTS PASSED ===");
        else             $display("\n=== %0d CHECK(S) FAILED ===", errors);
    end

endmodule
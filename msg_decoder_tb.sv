import itch_lite_pkg::*;

module msg_decoder_tb;

    timeunit 1ns; timeprecision 1ps;

    // Clock and reset
    logic clk = 0;
    always #5 clk = ~clk;   // 10ns period = 100MHz

    logic rst_n;

    // DUT connections
    logic         in_valid;
    logic [7:0]   in_byte;

    logic         msg_start;
    msg_type_e    msg_type_raw;
    logic         header_valid;
    logic [15:0]  stock_locate;
    logic [15:0]  tracking_number;
    logic [47:0]  timestamp;
    logic [63:0]  order_ref;
    payload_u     payload_raw;
    logic         msg_done;

    msg_decoder dut (.*);

    // Waveform dump
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, msg_decoder_tb);
    end

    // ---------------------------------------------------------------------
    // Helper task to send one byte into the DUT.
    task automatic send_byte(input logic [7:0] b);
        @(posedge clk); in_byte <= b; in_valid <= 1'b1;
        @(posedge clk); in_valid <= 1'b0;
    endtask

    // ---------------------------------------------------------------------
    // Byte arrays for one message of each type, built from ITCH standard
    
    // Add Order - 36 bytes
    logic [7:0] add_msg [0:35] = '{
        8'h41,                                                  // msg_type 'A'
        8'h00, 8'h01,                                           // stock_locate = 1
        8'h00, 8'h01,                                           // tracking_number = 1
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h64,               // timestamp = 100
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, // order_ref = 1
        8'h42,                                                  // side 'B' (buy)
        8'h00, 8'h00, 8'h00, 8'h64,                             // shares = 100
        8'h41, 8'h41, 8'h50, 8'h4C, 8'h20, 8'h20, 8'h20, 8'h20, // symbol "AAPL    "
        8'h00, 8'h07, 8'hA1, 8'h20                              // price = 500000
    };

    // Cancel Order - 23 bytes
    logic [7:0] cancel_msg [0:22] = '{
        8'h58,                                                   // msg_type 'X'
        8'h00, 8'h01,                                           // stock_locate = 1             
        8'h00, 8'h01,                                           // tracking_number = 1
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC8,               // timestamp = 200
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, // order_ref = 1
        8'h00, 8'h00, 8'h00, 8'h1E                              // cancelled_shares = 30
    };

    // Order Executed — 31 bytes
    logic [7:0] execute_msg [0:30] = '{
        8'h45,                                                  // msg_type 'E'
        8'h00, 8'h01,                                           // stock_locate = 1
        8'h00, 8'h01,                                           // tracking_number = 1
        8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h2C,               // timestamp = 300
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, // order_ref = 1
        8'h00, 8'h00, 8'h00, 8'h28,                             // executed_shares = 40
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h03, 8'hE8  // match_number = 1000
    };


    // ---------------------------------------------------------------------
    // Reset sequence
    initial begin
        rst_n    <= 0;
        in_valid <= 0;
        in_byte  <= 8'h00;

        repeat (3) @(posedge clk);
        rst_n   <= 1;
        @(posedge clk);
    end

    // ---------------------------------------------------------------------
    // Main stimulus — for each message array, loop through it
    // calling send_byte() for every element, then wait for msg_done to
    // pulse, then check the decoded outputs against what you expect.

    int errors = 0;

    task automatic check(string field_name, logic [63:0] actual, logic [63:0] expected);
        if (actual !== expected) begin
            $display("FAIL: %s = %0d, expected %0d", field_name, actual, expected);
            errors++;
        end else begin
            $display("PASS: %S = %0d", field_name, actual);
        end
    endtask

    initial begin
        // Wait for reset sequence
        @(posedge rst_n);
        @(posedge clk);

        // ---------------- Add Order ----------------
        $display("--- Sending Add Order ---");
        for (int i = 0; i < 36; i++) send_byte(add_msg[i]);
        #1;
        if (!msg_done) $display("FAIL: msg_done did not pulse after Add message");
        check("msg_type",        msg_type_raw,            MSG_ADD);
        check("stock_locate",    stock_locate,         1);
        check("tracking_number", tracking_number,      1);
        check("timestamp",       timestamp,            100);
        check("order_ref",       order_ref,            1);
        check("side",            payload_raw.add.side,     SIDE_BUY);
        check("shares",          payload_raw.add.shares,   100);
        check("price",           payload_raw.add.price,    500000);

        @(posedge clk); // let msg_done's 1-cycle pulse pass

        // ---------------- Order Cancel ----------------
        $display("--- Sending Cancel ---");
        for (int i = 0; i < 23; i++) send_byte(cancel_msg[i]);
        #1;
        if (!msg_done) $display("FAIL: msg_done did not pulse after Cancel message");
        check("msg_type",        msg_type_raw,             MSG_CANCEL);
        check("timestamp",       timestamp,             200);
        check("order_ref",       order_ref,             1);
        check("cancelled_shares",payload_raw.cancel.shares, 30);

        @(posedge clk);

        // ---------------- Order Executed ----------------
        $display("--- Sending Execute ---");
        for (int i = 0; i < 31; i++) send_byte(execute_msg[i]);
        #1;
        if (!msg_done) $display("FAIL: msg_done did not pulse after Execute message");
        check("msg_type",        msg_type_raw,              MSG_EXECUTE);
        check("timestamp",       timestamp,              300);
        check("order_ref",       order_ref,              1);
        check("executed_shares", payload_raw.execute.shares, 40);
        check("match_number",    payload_raw.execute.match,  1000);

        $finish;
    end

    // ---------------------------------------------------------------------
    // Error statistics display

    final begin
        if (errors == 0) $display("\n=== ALL TESTS PASSED ===");
        else              $display("\n=== %0d CHECK(S) FAILED ===", errors);
    end

endmodule
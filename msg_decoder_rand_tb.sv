import itch_lite_pkg::*;

module msg_decoder_rand_tb;

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
        $dumpvars(0, msg_decoder_rand_tb);
    end

    // ---------------------------------------------------------------------
    // Helper task to send one byte into the DUT.
    task automatic send_byte(input logic [7:0] b);
        @(posedge clk); in_byte <= b; in_valid <= 1'b1;
        @(posedge clk); in_valid <= 1'b0;
    endtask

    // ---------------------------------------------------------------------
    // Helper task to check actual vs expected values
    int errors = 0;
    task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
        if (actual !== expected) begin
            $display("FAIL: %s = %0d, expected %0d", name, actual, expected);
            errors++;
        end
    endtask

    // ---------------------------------------------------------------------
    // Reference model: builds a random message + the expected decoded values
    task automatic gen_and_check();
        int kind = $urandom_range(0,2);
        logic [15:0] r_locate      = $urandom_range(0, 65535);
        logic [15:0] r_track       = $urandom_range(0, 65535);
        logic [47:0] r_ts          = {$urandom, $urandom} & 48'hFFFF_FFFF_FFFF;
        logic [63:0] r_ref         = {$urandom, $urandom};
        logic [31:0] r_shares      = $urandom_range(1, 100000);
        logic [31:0] r_price       = $urandom_range(1, 2000000);
        logic [63:0] r_match       = {$urandom, $urandom};
        logic [7:0]  bytes[$];

        bytes = {};
        bytes.push_back(kind==0 ? MSG_ADD : kind==1 ? MSG_CANCEL : MSG_EXECUTE);
        bytes.push_back(r_locate[15:8]); bytes.push_back(r_locate[7:0]);
        bytes.push_back(r_track[15:8]);  bytes.push_back(r_track[7:0]);
        for (int i=5; i>=0; i--) bytes.push_back(r_ts[i*8 +: 8]);
        for (int i=7; i>=0; i--) bytes.push_back(r_ref[i*8 +: 8]);

        if (kind==0) begin // Add
        bytes.push_back(SIDE_BUY);
        for (int i=3; i>=0; i--) bytes.push_back(r_shares[i*8 +: 8]);
        for (int i=0; i<8; i++)  bytes.push_back(8'h20); // symbol, ignored by DUT
        for (int i=3; i>=0; i--) bytes.push_back(r_price[i*8 +: 8]);
        end else if (kind==1) begin // Cancel
        for (int i=3; i>=0; i--) bytes.push_back(r_shares[i*8 +: 8]);
        end else begin // Execute
        for (int i=3; i>=0; i--) bytes.push_back(r_shares[i*8 +: 8]);
        for (int i=7; i>=0; i--) bytes.push_back(r_match[i*8 +: 8]);
        end

        foreach (bytes[i]) send_byte(bytes[i]);
        #1;

        if (!msg_done) begin $display("FAIL: msg_done did not pulse"); errors++; end
        check("stock_locate", stock_locate, r_locate);
        check("tracking_number", tracking_number, r_track);
        check("timestamp", timestamp, r_ts);
        check("order_ref", order_ref, r_ref);
        if (kind==0) begin
        check("side", payload_raw.add.side, SIDE_BUY);
        check("shares", payload_raw.add.shares, r_shares);
        check("price", payload_raw.add.price, r_price);
        end else if (kind==1) begin
        check("cancelled_shares", payload_raw.cancel.shares, r_shares);
        end else begin
        check("executed_shares", payload_raw.execute.shares, r_shares);
        check("match_number", payload_raw.execute.match, r_match);
        end
        @(posedge clk);
    endtask

    initial begin
        rst_n <= 0; in_valid <= 0; in_byte <= 8'h00;
        repeat (3) @(posedge clk);
        rst_n <= 1;
        @(posedge rst_n); @(posedge clk);

        repeat (200) gen_and_check(); // 200 randomized messages

        if (errors == 0) $display("=== ALL %0d RANDOM TESTS PASSED ===", 200);
        else              $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end
endmodule

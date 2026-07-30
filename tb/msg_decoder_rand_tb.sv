/* verilator lint_off IMPORTSTAR */
import itch_lite_pkg::*;
/* verilator lint_on IMPORTSTAR */

module msg_decoder_rand_tb;

    timeunit 1ns; timeprecision 1ps;

    // Clock and reset
    logic clk = 0;
    always #5 clk = ~clk;   // 10ns period = 100MHz

    logic rst_n;

    // DUT AXI-Stream Slave interface
    logic [63:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic [7:0]  s_axis_tkeep;
    logic        s_axis_tlast;
    logic        s_axis_tready;

    // DUT Control & Status interface
    logic        m_axis_tready;
    logic        msg_start;
    logic        header_valid;
    logic        msg_done;
    logic        framing_error;
    logic [287:0] order_event_raw;

    // Unpack raw 288-bit vector to structured type for clean checking
    order_event_t order_event;
    assign order_event = order_event_t'(order_event_raw);

    msg_decoder dut (.*);

    // Waveform dump
    initial begin
        $dumpfile("dump_rand.vcd");
        $dumpvars(0, msg_decoder_rand_tb);
    end

    // ---------------------------------------------------------------------
    // MODULE-SCOPE QUEUE (Bypasses Icarus Verilog automatic argument bug)
    // ---------------------------------------------------------------------
    logic [7:0] tx_queue[$];

    // ---------------------------------------------------------------------
    // 64-Bit AXI-Stream Driver Task (Consumes tx_queue directly)
    // ---------------------------------------------------------------------
    task automatic send_message(input logic set_tlast = 1'b1);
        while (tx_queue.size() > 0) begin
            logic [63:0] word_data = '0;
            logic [7:0]  word_keep = '0;
            int n = (tx_queue.size() >= 8) ? 8 : tx_queue.size();

            // Pack up to 8 bytes into little-endian AXI-Stream byte lanes
            for (int i = 0; i < n; i++) begin
                word_data[i*8 +: 8] = tx_queue.pop_front();
                word_keep[i]        = 1'b1;
            end

            s_axis_tdata  <= word_data;
            s_axis_tkeep  <= word_keep;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= (tx_queue.size() == 0 && set_tlast) ? 1'b1 : 1'b0;

            // Wait for handshake on rising clock edge
            do begin
                @(posedge clk);
            end while (!s_axis_tready);
        end

        // Deassert bus after all words are accepted
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        s_axis_tkeep  <= '0;
        s_axis_tdata  <= '0;
    endtask

    // ---------------------------------------------------------------------
    // Synchronization Task: Wait for NBA settling, then check completion
    // ---------------------------------------------------------------------
    int errors = 0;
    task automatic wait_and_check_done();
        #1; // Step past NBA region to prevent delta-cycle sampling races
        
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

    // ---------------------------------------------------------------------
    // Value Checker Task
    // ---------------------------------------------------------------------
    task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
        if (actual !== expected) begin
            $display("FAIL: %s = %0d, expected %0d", name, actual, expected);
            errors++;
        end
    endtask

    // ---------------------------------------------------------------------
    // Random Message Generator & Checker
    // ---------------------------------------------------------------------
    task automatic gen_and_check();
        int kind = $urandom_range(0, 2);
        logic [15:0] r_locate = $urandom_range(0, 65535);
        logic [15:0] r_track  = $urandom_range(0, 65535);
        logic [47:0] r_ts     = {$urandom, $urandom} & 48'hFFFF_FFFF_FFFF;
        logic [63:0] r_ref    = {$urandom, $urandom};
        logic [31:0] r_shares = $urandom_range(1, 100000);
        logic [31:0] r_price  = $urandom_range(1, 2000000);
        logic [63:0] r_match  = {$urandom, $urandom};

        // Populate the shared module-level queue
        tx_queue = {};
        tx_queue.push_back(kind == 0 ? MSG_ADD : kind == 1 ? MSG_CANCEL : MSG_EXECUTE);
        tx_queue.push_back(r_locate[15:8]); tx_queue.push_back(r_locate[7:0]);
        tx_queue.push_back(r_track[15:8]);  tx_queue.push_back(r_track[7:0]);
        for (int i = 5; i >= 0; i--) tx_queue.push_back(r_ts[i*8 +: 8]);
        for (int i = 7; i >= 0; i--) tx_queue.push_back(r_ref[i*8 +: 8]);

        if (kind == 0) begin // Add
            tx_queue.push_back(SIDE_BUY);
            for (int i = 3; i >= 0; i--) tx_queue.push_back(r_shares[i*8 +: 8]);
            for (int i = 0; i < 8; i++)  tx_queue.push_back(8'h20); // symbol (skipped by DUT)
            for (int i = 3; i >= 0; i--) tx_queue.push_back(r_price[i*8 +: 8]);
        end else if (kind == 1) begin // Cancel
            for (int i = 3; i >= 0; i--) tx_queue.push_back(r_shares[i*8 +: 8]);
        end else begin // Execute
            for (int i = 3; i >= 0; i--) tx_queue.push_back(r_shares[i*8 +: 8]);
            for (int i = 7; i >= 0; i--) tx_queue.push_back(r_match[i*8 +: 8]);
        end

        // Stream over 64-bit AXI-Stream and wait for completion
        send_message(1'b1);
        wait_and_check_done();

        // Check decoded fields on the active, settled msg_done cycle
        check("stock_locate",    order_event.stock_locate,    r_locate);
        check("tracking_number", order_event.tracking_number, r_track);
        check("timestamp",       order_event.timestamp,       r_ts);
        check("order_ref",       order_event.order_ref,       r_ref);
        
        if (kind == 0) begin
            check("side",   order_event.payload.add.side,   SIDE_BUY);
            check("shares", order_event.payload.add.shares, r_shares);
            check("price",  order_event.payload.add.price,  r_price);
        end else if (kind == 1) begin
            check("cancelled_shares", order_event.payload.cancel.shares, r_shares);
        end else begin
            check("executed_shares", order_event.payload.execute.shares, r_shares);
            check("match_number",    order_event.payload.execute.match,  r_match);
        end
        
        @(posedge clk);
    endtask

    // ---------------------------------------------------------------------
    // Test Sequence
    // ---------------------------------------------------------------------
    initial begin
        rst_n         <= 0;
        s_axis_tvalid <= 0;
        s_axis_tdata  <= '0;
        s_axis_tkeep  <= '0;
        s_axis_tlast  <= 0;
        m_axis_tready <= 1; // Downstream consumer always ready

        repeat (3) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);

        repeat (200) gen_and_check(); // Run 200 randomized messages

        if (errors == 0) $display("=== ALL %0d RANDOM TESTS PASSED ===", 200);
        else             $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

endmodule
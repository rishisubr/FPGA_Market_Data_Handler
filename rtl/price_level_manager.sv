import itch_lite_pkg::*;
import lob_pkg::*;

module price_level_manager (
    input  logic        clk,
    input  logic        rst_n,

    // From order_table
    input  logic        update_valid,
    input  logic        update_is_bid,
    input  logic        update_is_add,
    input  logic [15:0] update_stock_locate,
    input  logic [31:0] update_price,
    input  logic [31:0] update_shares,

    // Status/Error outputs
    output  logic       price_table_evict_warn,
    output  logic       price_table_miss_err,

    // BBO query — downstream requests any symbol's BBO each cycle
    input  logic [15:0]  bbo_query_locate,
    output logic [128:0] bbo_out_raw,
    output logic         bbo_stale      // high when second-best was exhausted
                                        // and a rescan is pending


);

    // ------------------------------------------------------------------------
    // Memory array (inferred RAM)
    // ------------------------------------------------------------------------
    price_entry_t   mem [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [2:0]     plru [NUM_SETS-1:0]; 

    /// ------------------------------------------------------------------------
    // Hash function (10-bit XOR-fold)
    // ------------------------------------------------------------------------
    function automatic logic [SET_WIDTH-1:0] hash_price_key(input logic [15:0] locate_val, 
        input logic [31:0] price_val);

        logic [SET_WIDTH-1:0] h;
        h = price_val[9:0] ^
            price_val[19:10] ^
            price_val[29:20] ^
            {locate_val[7:0], price_val[31:30]} ^
            {2'b0, locate_val[15:8]};
        return h;
    endfunction

    // ------------------------------------------------------------------------
    // Combinational logic
    // ------------------------------------------------------------------------
    // Generate set index with hashing fucntion
    logic [SET_WIDTH-1:0] set_idx;
    assign set_idx = hash_price_key(update_stock_locate, update_price);

    // -----------------------
    // Match and hit detection
    logic [ASSOCIATIVITY-1:0] way_match;
    logic [ASSOCIATIVITY-1:0] way_valid;
    logic [1:0]               matched_way_idx;

    side_e target_side;
    assign target_side = update_is_bid ? SIDE_BUY : SIDE_SELL;

    always_comb begin
        way_match       = '0;
        way_valid       = '0;
        matched_way_idx = '0;

        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            way_valid[i] = mem[set_idx][i].valid;

            // A hit requires matching all 3 fields of the composite key
            if (way_valid[i] && 
                (mem[set_idx][i].stock_locate == update_stock_locate) &&
                (mem[set_idx][i].price        == update_price) &&
                (mem[set_idx][i].side         == target_side)) begin
        
                way_match[i]    = 1'b1;
                matched_way_idx = i[1:0];
            end
        end
    end

    logic hit;  // Active hit indicator across the set
    assign hit = |way_match;

    // ----------------------------------------                           
    // Allocation with free way search (MSG_ADD)
    logic [1:0] empty_way;
    logic       has_empty;

    always_comb begin
        empty_way = '0;
        has_empty = 1'b0;
        for (int i = ASSOCIATIVITY-1; i >= 0; i--) begin
            if (!mem[set_idx][i].valid) begin
                empty_way = i[1:0];
                has_empty = 1'b1;
            end
        end
    end

    // Eviction policy with tree-based PLRU victim selection
    logic [1:0] plru_victim;

    always_comb begin
        if (!plru[set_idx][0]) begin
            plru_victim = !plru[set_idx][1] ? 2'd0 : 2'd1;
        end else begin 
            plru_victim = !plru[set_idx][2] ? 2'd2 : 2'd3;
        end
    end

    // final allocation routing, prioritizing empty slots with PLRU victim fallback
    logic [1:0] alloc_way;
    assign alloc_way = has_empty ? empty_way : plru_victim;

    // ------------------------------------------------------------------------
    // Sequential State Update & Table Mutation
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            price_table_evict_warn <= '0;
            price_table_miss_err <= '0;
            
            // Clear RAM
            for (int s = 0; s < NUM_SETS; s++) begin
                plru[s] <= '0;
                for (int w = 0; w < ASSOCIATIVITY; w++) begin
                    mem[s][w] <= '0;
                end
            end
        end else begin
            // Default clear each cycle
            price_table_evict_warn <= '0;
            price_table_miss_err <= '0;
            
            if (update_valid) begin
                // VOLUME ADDITION (new order or adding to existing level)
                if (update_is_add) begin
                    
                    // price bucket exists, aggregate shares
                    if (hit) begin
                        mem[set_idx][matched_way_idx].shares 
                            <= mem[set_idx][matched_way_idx].shares + update_shares;
                        plru[set_idx] <= plru_update(plru[set_idx], matched_way_idx);
                    
                    // price bucket d.n.e., allocate new levle
                    end else begin
                        if (!has_empty) begin
                            price_table_evict_warn <= 1'b1; // flag eviction policy used
                        end

                        mem[set_idx][alloc_way].valid        <= 1'b1;
                        mem[set_idx][alloc_way].side         <= target_side;
                        mem[set_idx][alloc_way].stock_locate <= update_stock_locate;
                        mem[set_idx][alloc_way].price        <= update_price;
                        mem[set_idx][alloc_way].shares       <= update_shares;

                        plru[set_idx] <= plru_update(plru[set_idx], alloc_way);
                    end

                // VOLUME REDUCTION (cancel or execute)
                end else begin
                    if (hit) begin
                        if (update_shares >= mem[set_idx][matched_way_idx].shares) begin
                        // Price level completely exhausted, clear the bucket
                        mem[set_idx][matched_way_idx].valid  <= 1'b0;
                        mem[set_idx][matched_way_idx].shares <= '0;
                        
                        end else begin
                        // Partial reduction, subtract shares
                        mem[set_idx][matched_way_idx].shares <= 
                            mem[set_idx][matched_way_idx].shares - update_shares;
                        end

                        plru[set_idx] <= plru_update(plru[set_idx], matched_way_idx);
                    end else begin
                        price_table_miss_err <= 1'b1;  // flag missed cancel/execute
                    end 
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // BBO LUTRAM — 4096 symbols Stores best and second-best bid/ask levels.
    // Updated when a price level changes.
    // ------------------------------------------------------------------------

    bbo_entry_t bbo_lut [NUM_SYMBOLS-1:0];

    // Internal typed BBO output — flat port assigned below
    bbo_t bbo_out_typed;
    assign bbo_out_raw = bbo_out_typed;

    // ------------------------------------------------------------------------
    // BBO query — combinational LUT read.
    // ------------------------------------------------------------------------
    bbo_entry_t queried;
    assign queried = bbo_lut[bbo_query_locate[SYMBOL_IDX_WIDTH-1:0]];
    always_comb begin
        bbo_out_typed.valid      = queried.bid_best_valid || queried.ask_best_valid;
        bbo_out_typed.bid_price  = queried.bid_best_price;
        bbo_out_typed.bid_shares = queried.bid_best_shares;
        bbo_out_typed.ask_price  = queried.ask_best_price;
        bbo_out_typed.ask_shares = queried.ask_best_shares;
    end

    // ------------------------------------------------------------------------
    // BBO update rules:
    //
    // ADD:
    //   - Promote better prices to best.
    //   - Demote old best to second.
    //   - Aggregate matching prices.
    //   - Ignore prices below tracked depth.
    //
    // REDUCE:
    //   - Update shares for tracked levels.
    //   - Promote second when best is removed.
    //   - Set stale if no replacement exists.
    // ------------------------------------------------------------------------

     // Registered bbo_stale — cleared each cycle, set when promotion fails
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bbo_stale <= '0;
            for (int i = 0; i < NUM_SYMBOLS; i++)
                bbo_lut[i] <= '0;
        end else begin
            bbo_stale <= '0;  // default clear

            if (update_valid) begin
                automatic logic [SYMBOL_IDX_WIDTH-1:0] sym;
                automatic bbo_entry_t              e;
                automatic logic [31:0]             new_shares_after;

                sym = update_stock_locate[SYMBOL_IDX_WIDTH-1:0];
                e   = bbo_lut[sym];  // latch current entry for this symbol

                if (update_is_bid) begin
                    // --------------------------------------------------------
                    // BID SIDE
                    // --------------------------------------------------------
                    if (update_is_add) begin
                        // Volume addition on bid side
                        if (!e.bid_best_valid) begin
                            // No best yet — this becomes best
                            e.bid_best_valid  = 1'b1;
                            e.bid_best_price  = update_price;
                            e.bid_best_shares = update_shares;

                        end else if (update_price > e.bid_best_price) begin
                            // New price beats current best — demote best to 2nd
                            e.bid_2nd_valid   = e.bid_best_valid;
                            e.bid_2nd_price   = e.bid_best_price;
                            e.bid_2nd_shares  = e.bid_best_shares;
                            e.bid_best_price  = update_price;
                            e.bid_best_shares = update_shares;

                        end else if (update_price == e.bid_best_price) begin
                            // Same price as best — aggregate shares
                            e.bid_best_shares = e.bid_best_shares + update_shares;

                        end else if (!e.bid_2nd_valid || update_price > e.bid_2nd_price) begin
                            // Better than 2nd (or 2nd slot empty) — update 2nd
                            e.bid_2nd_valid   = 1'b1;
                            e.bid_2nd_price   = update_price;
                            e.bid_2nd_shares  = update_shares;

                        end else if (update_price == e.bid_2nd_price) begin
                            // Same price as 2nd — aggregate
                            e.bid_2nd_shares  = e.bid_2nd_shares + update_shares;
                        end
                        // Deeper than 2nd — no BBO update needed

                    end else begin
                        // Volume reduction on bid side
                        new_shares_after = (update_shares >= e.bid_best_shares) ?
                                           32'h0 :
                                           e.bid_best_shares - update_shares;

                        if (update_price == e.bid_best_price) begin
                            if (new_shares_after == 0) begin
                                // Best exhausted — promote 2nd to best
                                if (e.bid_2nd_valid) begin
                                    e.bid_best_price  = e.bid_2nd_price;
                                    e.bid_best_shares = e.bid_2nd_shares;
                                    e.bid_2nd_valid   = 1'b0;
                                    e.bid_2nd_price   = '0;
                                    e.bid_2nd_shares  = '0;
                                end else begin
                                    // 2nd also invalid — BBO exhausted
                                    e.bid_best_valid  = 1'b0;
                                    e.bid_best_price  = '0;
                                    e.bid_best_shares = '0;
                                    bbo_stale         <= 1'b1;
                                end
                            end else begin
                                // Partial reduction of best
                                e.bid_best_shares = new_shares_after;
                            end

                        end else if (update_price == e.bid_2nd_price) begin
                            // Reduction hits 2nd level
                            if (update_shares >= e.bid_2nd_shares) begin
                                e.bid_2nd_valid  = 1'b0;
                                e.bid_2nd_price  = '0;
                                e.bid_2nd_shares = '0;
                                bbo_stale        <= 1'b1;  // 2nd exhausted, rescan needed
                            end else begin
                                e.bid_2nd_shares = e.bid_2nd_shares - update_shares;
                            end
                        end
                        // Price deeper than 2nd — no BBO change
                    end

                end else begin
                    // --------------------------------------------------------
                    // ASK SIDE — mirror image of bid, lower price is better
                    // --------------------------------------------------------
                    if (update_is_add) begin
                        if (!e.ask_best_valid) begin
                            e.ask_best_valid  = 1'b1;
                            e.ask_best_price  = update_price;
                            e.ask_best_shares = update_shares;

                        end else if (update_price < e.ask_best_price) begin
                            // Lower price beats current best ask
                            e.ask_2nd_valid   = e.ask_best_valid;
                            e.ask_2nd_price   = e.ask_best_price;
                            e.ask_2nd_shares  = e.ask_best_shares;
                            e.ask_best_price  = update_price;
                            e.ask_best_shares = update_shares;

                        end else if (update_price == e.ask_best_price) begin
                            e.ask_best_shares = e.ask_best_shares + update_shares;

                        end else if (!e.ask_2nd_valid || update_price < e.ask_2nd_price) begin
                            e.ask_2nd_valid   = 1'b1;
                            e.ask_2nd_price   = update_price;
                            e.ask_2nd_shares  = update_shares;

                        end else if (update_price == e.ask_2nd_price) begin
                            e.ask_2nd_shares  = e.ask_2nd_shares + update_shares;
                        end

                    end else begin
                        // Volume reduction on ask side
                        new_shares_after = (update_shares >= e.ask_best_shares) ?
                                           32'h0 :
                                           e.ask_best_shares - update_shares;

                        if (update_price == e.ask_best_price) begin
                            if (new_shares_after == 0) begin
                                if (e.ask_2nd_valid) begin
                                    e.ask_best_price  = e.ask_2nd_price;
                                    e.ask_best_shares = e.ask_2nd_shares;
                                    e.ask_2nd_valid   = 1'b0;
                                    e.ask_2nd_price   = '0;
                                    e.ask_2nd_shares  = '0;
                                end else begin
                                    e.ask_best_valid  = 1'b0;
                                    e.ask_best_price  = '0;
                                    e.ask_best_shares = '0;
                                    bbo_stale         <= 1'b1;
                                end
                            end else begin
                                e.ask_best_shares = new_shares_after;
                            end

                        end else if (update_price == e.ask_2nd_price) begin
                            if (update_shares >= e.ask_2nd_shares) begin
                                e.ask_2nd_valid  = 1'b0;
                                e.ask_2nd_price  = '0;
                                e.ask_2nd_shares = '0;
                                bbo_stale        <= 1'b1;
                            end else begin
                                e.ask_2nd_shares = e.ask_2nd_shares - update_shares;
                            end
                        end
                    end
                end

                // Write the modified entry back to LUTRAM
                bbo_lut[sym] <= e;
            end
        end
    end

endmodule
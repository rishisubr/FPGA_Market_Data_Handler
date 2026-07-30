package lob_pkg;

    import itch_lite_pkg::*;
    
    // ------------------------------------------------------------------------
    // Sizing parameters
    // ------------------------------------------------------------------------
    // MAX_ORDERS       : Max individual orders tracked (by order_ref)
    // MAX_PRICE_LEVELS : Max aggregated volume buckets (by locate + side + price)
    // NUM_SYMBOLS      : Max unique instruments for the direct-mapped BBO cache
    localparam int MAX_ORDERS = 4096, MAX_PRICE_LEVELS = 4096, NUM_SYMBOLS = 4096;
    
    localparam int ASSOCIATIVITY = 4;
    localparam int NUM_SETS = MAX_ORDERS / ASSOCIATIVITY;
    localparam int SET_WIDTH = $clog2(NUM_SETS);                // 10 bits
    localparam int SYMBOL_IDX_WIDTH = $clog2(NUM_SYMBOLS);      // 12 bits

    // ------------------------------------------------------------------------
    // Entry to order manager RAM
    // ------------------------------------------------------------------------
    typedef struct packed{
        logic           valid;
        side_e          side;
        logic [15:0]    stock_locate;
        price_t         price;
        logic [31:0]    shares;
        logic [63:0]    order_ref;
    } order_entry_t;

    // ------------------------------------------------------------------------
    // Entry to price manager RAM
    // ------------------------------------------------------------------------
    typedef struct packed {
        logic           valid;
        side_e          side;
        logic [15:0]    stock_locate;
        price_t         price;
        logic [31:0]    shares;
    } price_entry_t;


    // ------------------------------------------------------------------------
    // Best Bid & Offer (BBO) output structs
    // ------------------------------------------------------------------------
    typedef struct packed {
        logic           valid;
        price_t         bid_price;
        logic [31:0]    bid_shares;
        price_t         ask_price;
        logic[31:0]     ask_shares;
    } bbo_t; 
    
    typedef struct packed {
        // Best bid
        logic           bid_best_valid;
        logic [31:0]    bid_best_price;
        logic[31:0]     bid_best_shares;
        // 2nd best bid
        logic           bid_2nd_valid;
        logic [31:0]    bid_2nd_price;
        logic[31:0]     bid_2nd_shares;
        // Best ask
        logic           ask_best_valid;
        logic [31:0]    ask_best_price;
        logic[31:0]     ask_best_shares;
        // 2nd best ask
        logic           ask_2nd_valid;
        logic [31:0]    ask_2nd_price;
        logic[31:0]     ask_2nd_shares;
    } bbo_entry_t;

    // ------------------------------------------------------------------------
    // PLRU update logic
    // ------------------------------------------------------------------------
    function automatic logic [2:0] plru_update(input logic [2:0] current,
        input logic [1:0] way);
        logic [2:0] next;
        next = current;
        unique case (way)
            2'd0: begin next[0] = 1'b1; next[1] = 1'b1; end
            2'd1: begin next[0] = 1'b1; next[1] = 1'b0; end
            2'd2: begin next[0] = 1'b0; next[2] = 1'b1; end
            2'd3: begin next[0] = 1'b0; next[2] = 1'b0; end
            default: ;
        endcase
        return next;    
    endfunction

endpackage
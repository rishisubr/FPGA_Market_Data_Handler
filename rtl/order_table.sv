import itch_lite_pkg::*;
import lob_pkg::*;

module order_table(
    input   logic   clk,
    input   logic   rst_n,

    // Event input interface
    input   logic           event_valid,
    input   order_event_t   event_data,

    // Status/Error outputs
    output  logic       order_table_evict_warn,
    output  logic       order_table_miss_err,

    // Downstream Price Level Manager Broadcast Interface
    output logic        update_valid,
    output logic        update_is_bid,
    output logic        update_is_add,
    output logic [15:0] update_stock_locate,
    output logic [31:0] update_price,
    output logic [31:0] update_shares
);

    // ------------------------------------------------------------------------
    // Memory array (inferred RAM)
    // ------------------------------------------------------------------------
    order_entry_t   mem [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [2:0]     plru [NUM_SETS-1:0]; 

    // ------------------------------------------------------------------------
    // Hash function (10-bit XOR-fold)
    // ------------------------------------------------------------------------
    function automatic logic [SET_WIDTH-1:0] hash_order_ref(input logic [63:0] ref_val);
        logic [SET_WIDTH-1:0] h;
        h = ref_val[9:0] ^
            ref_val[19:10] ^
            ref_val[29:20] ^
            ref_val[39:30] ^
            ref_val[49:40] ^
            ref_val[59:50] ^
            {6'b0, ref_val[63:60]};
        return h;
    endfunction

    // ------------------------------------------------------------------------
    // Combinational logic
    // ------------------------------------------------------------------------
    // Generate set index with hashing fucntion
    logic [SET_WIDTH-1:0] set_idx;
    assign set_idx = hash_order_ref(event_data.order_ref);

    // -----------------------
    // Match and hit detection
    logic [ASSOCIATIVITY-1:0] way_match;
    logic [ASSOCIATIVITY-1:0] way_valid;
    logic [1:0]               matched_way_idx;

    always_comb begin
        way_match       = '0;
        way_valid       = '0;
        matched_way_idx = '0;

        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            way_valid[i] = mem[set_idx][i].valid;
            if (way_valid[i] && (mem[set_idx][i].order_ref == event_data.order_ref)) begin
                way_match[i]    = 1'b1;
                matched_way_idx = i[1:0];
            end
        end
    end

    logic hit;  // Active hit indicator across the set
    assign hit = |way_match;

    // Event payload share extraction
    logic [31:0] target_shares;
    assign target_shares = (event_data.msg_type == MSG_EXECUTE) ? 
                           event_data.payload.execute.shares : 
                           event_data.payload.cancel.shares;


    // -----------------------------------------
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
            order_table_evict_warn <= '0;
            order_table_miss_err <= '0;
            update_valid <= '0;
            
            // Clear RAM
            for (int s = 0; s < NUM_SETS; s++) begin
                plru[s] <= '0;
                for (int w = 0; w < ASSOCIATIVITY; w++) begin
                    mem[s][w] <= '0;
                end
            end

        end else begin
            // Default clear each cycle
            order_table_evict_warn <= '0;
            order_table_miss_err <= '0;
            update_valid <= '0;

            if (event_valid) begin
                unique case (event_data.msg_type)
                    MSG_ADD: begin
                        // Insert new order into RAM
                        mem[set_idx][alloc_way].valid        <= 1'b1;
                        mem[set_idx][alloc_way].side         <= event_data.payload.add.side;
                        mem[set_idx][alloc_way].price        <= event_data.payload.add.price;
                        mem[set_idx][alloc_way].shares       <= event_data.payload.add.shares;
                        mem[set_idx][alloc_way].stock_locate <= event_data.stock_locate;
                        mem[set_idx][alloc_way].order_ref    <= event_data.order_ref;
                        
                        // Flag if eviction policy was used
                        if (!has_empty) begin
                            order_table_evict_warn <= 1'b1;
                        end

                        // Broadcast Add update to Price Level Manager
                        update_valid        <= 1'b1;
                        update_is_bid       <= (event_data.payload.add.side == SIDE_BUY); // 'B' for Buy/Bid
                        update_is_add       <= 1'b1;
                        update_stock_locate <= event_data.stock_locate;
                        update_price        <= event_data.payload.add.price;
                        update_shares       <= event_data.payload.add.shares;
                        
                        // Update PLRU
                        plru[set_idx] <= plru_update(plru[set_idx], alloc_way);
                    end
                    
                    // Insert new order into RAM
                    MSG_CANCEL, MSG_EXECUTE: begin
                        if (hit) begin            
                            if (target_shares >= mem[set_idx][matched_way_idx].shares) begin
                                mem[set_idx][matched_way_idx].valid <= '0;
                                mem[set_idx][matched_way_idx].shares <= '0;
                            end else begin
                                mem[set_idx][matched_way_idx].shares <= 
                                    mem[set_idx][matched_way_idx].shares - target_shares;
                            end
                            
                            // Broadcast Reduction update to Price Level Manager
                            update_valid        <= 1'b1;
                            update_is_bid       <= (mem[set_idx][matched_way_idx].side == SIDE_BUY);
                            update_is_add       <= 1'b0;
                            update_stock_locate <= mem[set_idx][matched_way_idx].stock_locate;
                            update_price        <= mem[set_idx][matched_way_idx].price;
                            update_shares       <= (target_shares >= mem[set_idx][matched_way_idx].shares) ?
                                                    mem[set_idx][matched_way_idx].shares :
                                                    target_shares;

                            // Update PLRU
                            plru[set_idx] <= plru_update(plru[set_idx], matched_way_idx);

                        end else begin
                            order_table_miss_err <= 1'b1;
                        end
                    end
                    
                    default: ;
                endcase
            end
        end
    end

    // Safety assertion: ensure order_ref never matches >1 way in a set
    // lint_off SVA-ONEHOT
    always_ff @(posedge clk) begin
        if (rst_n && event_valid) begin
            assert($onehot0(way_match)) else
                $error("FATAL: Duplicate order_ref found across multiple ways in set %0d", set_idx);
        end
    end
    // lint_on SVA-ONEHOT

endmodule
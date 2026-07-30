/* verilator lint_off IMPORTSTAR */
import itch_lite_pkg::*;
import lob_pkg::*;
/* verilator lint_on IMPORTSTAR */

module lob_engine (
    input  logic         clk,
    input  logic         rst_n,

    // ------------------------------------------------------------------------
    // Raw Network Stream Input (AXI-Stream from MAC/PHY)
    // ------------------------------------------------------------------------
    input  logic [63:0]  s_axis_tdata,
    input  logic         s_axis_tvalid,
    input  logic [7:0]   s_axis_tkeep,
    input  logic         s_axis_tlast,
    output logic         s_axis_tready,

    // ------------------------------------------------------------------------
    // BBO Query Interface (Downstream Consumer)
    // ------------------------------------------------------------------------
    input  logic [15:0]  bbo_query_locate,
    output logic [128:0] bbo_out_raw,
    output logic         bbo_stale,

    // ------------------------------------------------------------------------
    // Telemetry & Error Flags
    // ------------------------------------------------------------------------
    output logic         decoder_framing_error,
    output logic         order_table_evict_warn,
    output logic         order_table_miss_err,
    output logic         price_table_evict_warn,
    output logic         price_table_miss_err
);

    // ------------------------------------------------------------------------
    // Internal interconnect: Decoder -> Order Table
    // ------------------------------------------------------------------------
    logic         msg_done;
    logic [287:0] order_event_raw;
    order_event_t parsed_event;
    
    // Cast the flat 288-bit logic array back to the struct for the order table
    assign parsed_event = order_event_t'(order_event_raw);

    // Unused decoder telemetry wires
    logic         msg_start;
    logic         header_valid;

    // ------------------------------------------------------------------------
    // Internal interconnect: Order Table -> Price Level Manager
    // ------------------------------------------------------------------------
    logic         update_valid;
    logic         update_is_bid;
    logic         update_is_add;
    logic [15:0]  update_stock_locate;
    logic [31:0]  update_price;
    logic [31:0]  update_shares;

    // ------------------------------------------------------------------------
    // Stage 0: Message Decoder
    // Parses incoming 64-bit network words into structured ITCH events
    // ------------------------------------------------------------------------
    msg_decoder u_decoder (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // AXI-Stream Input
        .s_axis_tdata           (s_axis_tdata),
        .s_axis_tvalid          (s_axis_tvalid),
        .s_axis_tkeep           (s_axis_tkeep),
        .s_axis_tlast           (s_axis_tlast),
        .s_axis_tready          (s_axis_tready),

        // Control / Status
        .m_axis_tready          (1'b1), // Pipeline never backpressures
        .msg_start              (msg_start),
        .header_valid           (header_valid),
        .msg_done               (msg_done),
        .framing_error          (decoder_framing_error),

        // Output
        .order_event_raw        (order_event_raw)
    );

    // ------------------------------------------------------------------------
    // Stage 1: Order Table
    // Tracks individual order states and generates delta volume updates
    // ------------------------------------------------------------------------
    order_table u_order_table (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // Feed from decoder
        .event_valid            (msg_done),
        .event_data             (parsed_event),
        
        // Feed into price manager
        .update_valid           (update_valid),
        .update_is_bid          (update_is_bid),
        .update_is_add          (update_is_add),
        .update_stock_locate    (update_stock_locate),
        .update_price           (update_price),
        .update_shares          (update_shares),

        // Telemetry
        .order_table_evict_warn (order_table_evict_warn),
        .order_table_miss_err   (order_table_miss_err)
    );

    // ------------------------------------------------------------------------
    // Stage 2: Price Level Manager
    // Aggregates volume by price level and maintains the Two-Level BBO cache
    // ------------------------------------------------------------------------
    price_level_manager u_price_manager (
        .clk                    (clk),
        .rst_n                  (rst_n),

        // Feed from order table
        .update_valid           (update_valid),
        .update_is_bid          (update_is_bid),
        .update_is_add          (update_is_add),
        .update_stock_locate    (update_stock_locate),
        .update_price           (update_price),
        .update_shares          (update_shares),

        // Telemetry
        .price_table_evict_warn (price_table_evict_warn),
        .price_table_miss_err   (price_table_miss_err),

        // BBO Query Interface
        .bbo_query_locate       (bbo_query_locate),
        .bbo_out_raw            (bbo_out_raw),
        .bbo_stale              (bbo_stale)
    );

endmodule
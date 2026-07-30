package itch_lite_pkg;
    // ------------------------------------------------------------------------
    // Message & side type tags (ITCH standard)
    // ------------------------------------------------------------------------
    typedef enum logic [7:0] {
        MSG_ADD     = "A",
        MSG_CANCEL  = "X",
        MSG_EXECUTE = "E"
    } msg_type_e;

    typedef enum logic [7:0] {
        SIDE_BUY    = "B",
        SIDE_SELL   = "S"
    } side_e;

    typedef logic unsigned [31:0] price_t;       // fixed point, units of $0.0001

    // ------------------------------------------------------------------------
    // Fixed message lengths
    // ------------------------------------------------------------------------
    localparam int unsigned ADD_LEN      = 36;
    localparam int unsigned CANCEL_LEN   = 23;
    localparam lint unsigned EXECUTE_LEN  = 31;

    // ------------------------------------------------------------------------
    // Individual variant payloads (padded to 17 bytes = 136 bits)
    // ------------------------------------------------------------------------

    // MSG_ADD payload
    typedef struct packed {
        side_e       side;        // 8 bits
        logic [31:0] shares;      // 32 bits
        price_t      price;       // 32 bits
        logic [63:0] _padding;    // 64 bits padding
    } add_payload_t;

    // MSG_CANCEL payload
    typedef struct packed {
        logic [31:0]  shares;     // 32 bits
        logic [103:0] _padding;   // 104 bits padding
    } cancel_payload_t;

    // MSG_EXECUTE payload
    typedef struct packed {
        logic [31:0] shares;      // 32 bits
        logic [63:0] match;       // 64 bits
        logic [39:0] _padding;    // 40 bits padding
    } execute_payload_t;

    // Overlapped payload union (136 bits)
    typedef union packed {
        add_payload_t       add;
        cancel_payload_t    cancel;
        execute_payload_t   execute;
    } payload_u;

    // ------------------------------------------------------------------------
    // Decoded output event struct
    // ------------------------------------------------------------------------
    typedef struct packed {
        msg_type_e      msg_type;        // 8 bits
        logic [15:0]    stock_locate;    // 16 bits
        logic [15:0]    tracking_number; // 16 bits
        logic [47:0]    timestamp;       // 48 bits
        logic [63:0]    order_ref;       // 64 bits
        payload_u       payload;         // 136 bits
    } order_event_t;

    localparam int ORDER_EVENT_BITS = $bits(order_event_t);
    initial begin
        assert(ORDER_EVENT_BITS == 288);
    end

    // ------------------------------------------------------------------------
    // Endianness byte-swap functions (big-endian ITCH -> little-endian FPGA)
    // ------------------------------------------------------------------------

    function automatic logic [15:0] bswap16(input logic [15:0] val);
        return {val[7:0], val[15:8]};
    endfunction

    function automatic logic [31:0] bswap32(input logic [31:0] val);
        return {val[7:0], val[15:8], val[23:16], val[31:24]};
    endfunction

    function automatic logic [47:0] bswap48(input logic [47:0] val);
        return {
            val[7:0],   val[15:8],  val[23:16],
            val[31:24], val[39:32], val[47:40]
        };
    endfunction

    function automatic logic [63:0] bswap64(input logic [63:0] val);
        return {
            val[7:0],   val[15:8],  val[23:16], val[31:24],
            val[39:32], val[47:40], val[55:48], val[63:56]
        };
    endfunction

endpackage
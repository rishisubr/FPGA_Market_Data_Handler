package itch_lite_pkg;

    // Message and side type tags, based on ITCH standard
    typedef enum logic [7:0] {
        MSG_ADD     = "A",
        MSG_CANCEL  = "X",
        MSG_EXECUTE = "E"
    } msg_type_e;

    typedef enum logic[7:0] {
        SIDE_BUY    = "B",
        SIDE_SELL   = "S"
    } side_e;

    typedef logic [31:0] price_t;       // fixed point, units of $0.0001

    // Fixed message lengths
    localparam logic[7:0] ADD_LEN      = 36;
    localparam logic[7:0] CANCEL_LEN   = 23;
    localparam logic[7:0] EXECUTE_LEN  = 31;

    // Individual variant payloads
    typedef struct packed {
        side_e       side;
        logic [31:0] shares;
        price_t      price;
        logic [23:0] reserved; // padding
    } add_payload_t;

    typedef struct packed {
        logic [31:0] shares;
        logic [63:0] reserved; // padding
    } cancel_payload_t;

    typedef struct packed {
        logic [31:0] shares;
        logic [63:0] match;
    } execute_payload_t;
    
    // Overlapped union variant payload
    typedef union packed {
        add_payload_t       add;
        cancel_payload_t    cancel;
        execute_payload_t   execute;
    } payload_u;

    // Decoded output event - only fields relevant to msg_type are 
    // meaningful for given event
    typedef struct packed {
        msg_type_e  msg_type;
        logic[15:0] stock_locate;
        logic[15:0] tracking_number;
        logic[47:0] timestamp;
        logic[63:0] order_ref;
        payload_u   payload;    // shared physical 96 bits
    } order_event_t;

endpackage

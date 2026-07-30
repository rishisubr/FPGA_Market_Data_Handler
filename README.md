# FMDH: FPGA-Accelerated ITCH Feed Handler and Limit Order Book

FMDH is a hardware-accelerated NASDAQ ITCH 5.0 feed handler and limit order book (LOB) engine implemented in SystemVerilog. The project explores how exchange data processing can be moved into deterministic FPGA hardware to achieve extremely low-latency market data processing.

The system receives raw AXI4-Stream network data, parses exchange messages, maintains live order state, and produces real-time Best Bid and Offer (BBO) updates with predictable cycle-level latency.

## Architecture Overview

### Line-Rate Streaming Pipeline

The design uses a fully pipelined streaming architecture that processes incoming exchange messages without stalling. The AXI4-Stream interface is configured with `m_axis_tready` permanently asserted, allowing the engine to continuously consume data at line rate while maintaining deterministic latency.

### Fast Top-of-Book Updates

To avoid repeatedly searching through the order book for the best prices, FMDH maintains a two-level shadow cache for top-of-book information.

The cache allows:

- Single-cycle BBO updates when the best price changes
- Immediate promotion of the next-best price level
- Constant-time access to downstream execution logic

This avoids expensive background scans of the full order book.

### Efficient Memory Management

NASDAQ `stock_locate` identifiers are sparse 16-bit values, making direct memory allocation inefficient. Instead, FMDH uses custom hash-based associative tables to map exchange identifiers into limited FPGA memory resources.

Cache replacement is managed using tree-based pseudo-LRU (PLRU) logic, allowing the system to efficiently handle collisions while maintaining predictable hardware timing.

### Hardware Telemetry

The design includes built-in telemetry signals for debugging and validation, including detection of:

- Invalid ITCH message framing
- Payload length violations
- Associative cache eviction events

These hardware-level diagnostics make it easier to verify behavior during simulation and deployment.

---

# Pipeline Design

The engine is divided into three main processing stages.

## 1. `msg_decoder` — ITCH Message Parser

The first stage receives raw network bytes from the AXI4-Stream interface and reconstructs ITCH 5.0 messages using a 128-bit sliding window parser.

The decoder identifies message types including:

- `MSG_ADD` — new order creation
- `MSG_CANCEL` — order cancellation
- `MSG_EXECUTE` — order execution

It also validates message boundaries and framing to prevent malformed packets from propagating into later stages.

---

## 2. `order_table` — Live Order Tracking

The order table maintains the state of active orders using unique 64-bit `order_ref` identifiers.

Instead of passing complete exchange messages downstream, this stage converts incoming events into volume changes:

- Add messages create new liquidity
- Cancel messages remove liquidity
- Execute messages reduce remaining order size

This allows the price-level manager to operate on simple volume deltas rather than individual orders.

---

## 3. `price_level_manager` — Liquidity Aggregation

The price-level manager aggregates orders into price buckets separated by:

- Instrument
- Side (bid/ask)
- Price level

It maintains the current liquidity distribution and updates the top-of-book cache whenever the best bid or ask changes.

The output of this stage is a continuously updated BBO stream suitable for downstream trading logic.

---

# Memory Data Model

The design separates state storage into three main structures:

## Order Tracking

Tracks individual live orders:

# ITCH-Lite Feed Handler

A synthesizable SystemVerilog streaming feed handler based on NASDAQ ITCH 5.0. Parses incoming bytes per clock cycle and outputs decoded order events without frame buffering.

## Supported Messages

| Message | Code | Length | Payload Fields |
| :--- | :--- | :--- | :--- |
| **Add Order** | `'A'` | 36B | Side (1B), Shares (4B), Symbol (8B, skipped), Price (4B) |
| **Order Cancel** | `'X'` | 23B | Cancelled Shares (4B) |
| **Order Executed** | `'E'` | 31B | Executed Shares (4B), Match ID (8B) |

*All messages share a 19-byte common header: Type (1B), Stock Locate (2B), Tracking Number (2B), Timestamp (6B), Order Ref (8B).*

## Architecture Highlights

* **Zero-Buffer Streaming:** Decodes fields directly into output registers byte-by-byte as data arrives on the `in_byte` interface.
* **Shift-and-Append:** Multi-byte big-endian fields use `{field[N-9:0], in_byte}` to eliminate dynamic bit-slice math.
* **Packed Union Payload:** Shares a single 96-bit `payload_u` union across message types to reduce register usage.

## Project Structure

* `itch_lite_pkg.sv` – Enums, packed structs, payload union, parameters.
* `msg_decoder.sv` – Core streaming decoder RTL with embedded SVA.
* `msg_decoder_tb.sv` – Directed single-frame testbench.
* `msg_decoder_rand_tb.sv` – Randomized testbench with inline reference model.
* `msg_decoder.sby` – SymbiYosys formal configuration.

## Commands

```bash
# Directed testbench
iverilog -g2012 -o sim itch_lite_pkg.sv msg_decoder.sv msg_decoder_tb.sv && vvp sim

# Randomized testbench (200 frames)
iverilog -g2012 -o sim_rand itch_lite_pkg.sv msg_decoder.sv msg_decoder_rand_tb.sv && vvp sim_rand

# Verilator lint
verilator --lint-only -Wall itch_lite_pkg.sv msg_decoder.sv

# View waveform
surfer dump.vcd
```

### SystemVerilog Assertions & Formal Verification

The RTL includes four embedded SVA properties under an `` `ifdef FORMAL `` guard:

* `p_byte_cnt_bounded` – Ensures `byte_cnt` never exceeds the valid length for the active `msg_type`.
* `p_msg_done_one_cycle` – Guarantees `msg_done` pulses for exactly one clock cycle.
* `p_cnt_resets_after_done` – Verifies `byte_cnt` resets to 0 the cycle after `msg_done`.
* `p_legal_msg_type` – Confirms `msg_type` remains a valid enum mid-frame.

Formal bounded model checking (`depth 50`) is set up via SymbiYosys (`msg_decoder.sby`). Yosys's SV frontend currently lacks support for package-imported `typedef union packed` types in module bodies, so full formal closure requires commercial solvers (e.g., Cadence JasperGold, Synopsys VC Formal) or a flattened RTL variant. All assertions execute cleanly during simulation-time checks.
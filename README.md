# ITCH-Lite Feed Handler

A synthesizable SystemVerilog 64-bit AXI-Stream streaming feed handler based on NASDAQ ITCH 5.0. Parses incoming packet words per clock cycle via a 128-bit sliding window, performs hardware endianness byte-swapping, and outputs decoded order events with full backpressure and error-recovery support.

## Supported Messages

| Message | Code | Length | Payload Fields |
| :--- | :--- | :--- | :--- |
| **Add Order** | `'A'` | 36B | Side (1B), Shares (4B), Symbol (8B, skipped), Price (4B)[cite: 1, 2] |
| **Order Cancel** | `'X'` | 23B | Cancelled Shares (4B)[cite: 1, 2] |
| **Order Executed** | `'E'` | 31B | Executed Shares (4B), Match ID (8B)[cite: 1, 2] |

*All messages share a 19-byte common header: Type (1B), Stock Locate (2B), Tracking Number (2B), Timestamp (6B), Order Ref (8B)[cite: 1, 2].*

## Architecture Highlights

* **64-Bit AXI-Stream Interface:** Standard streaming slave interface supporting `s_axis_tdata`, `s_axis_tvalid`, `s_axis_tkeep`, `s_axis_tlast`, and downstream backpressure via `m_axis_tready`[cite: 2].
* **128-Bit Sliding Window:** Stitches consecutive clock cycles together to seamlessly capture fields split across 8-byte word boundaries[cite: 2].
* **Endianness Byte-Swapping:** Built-in functions (`bswap16`, `bswap32`, `bswap48`, `bswap64`, `bswap136`) convert Big-Endian network byte order to Little-Endian FPGA representation with zero lookup table (0 LUT) overhead[cite: 1].
* **Packed Union Payload:** Shares a 136-bit `payload_u` union across variant message types[cite: 1].
* **Framing Error Recovery:** Detects truncated packets (`framing_error`) and unrecognized message types to instantly flush corrupted state and resynchronize the parser on the next packet boundary[cite: 2].

## Project Structure

* `itch_lite_pkg.sv` – Enums, packed structs, payload union, parameters, and byte-swap helper functions[cite: 1].
* `msg_decoder.sv` – Core streaming decoder RTL with sliding window, endianness mapping, and embedded SVA[cite: 2].
* `msg_decoder_tb.sv` – Directed single-frame testbench[cite: 4].
* `msg_decoder_rand_tb.sv` – Randomized verification suite (200 frames) with static queue architecture for safety[cite: 3].
* `msg_decoder_error_tb.sv` – Dedicated error-injection testbench verifying framing errors and unknown message flushes.
* `msg_decoder.sby` – SymbiYosys formal configuration.

## Commands

### Single Compilation & Execution Script
Run this single bash command to compile all three testbenches, execute them sequentially, format the outputs with clean headers, and save everything into `test_results.txt`:

```bash
echo "=== Directed Testbench ===" > test_results.txt && \
iverilog -g2012 -o sim itch_lite_pkg.sv msg_decoder.sv msg_decoder_tb.sv && vvp sim >> test_results.txt && \
echo -e "\n=== Randomized Testbench ===" >> test_results.txt && \
iverilog -g2012 -o sim_rand itch_lite_pkg.sv msg_decoder.sv msg_decoder_rand_tb.sv && vvp sim_rand >> test_results.txt && \
echo -e "\n=== Error Testbench ===" >> test_results.txt && \
iverilog -g2012 -o sim_err itch_lite_pkg.sv msg_decoder.sv msg_decoder_error_tb.sv && vvp sim_err >> test_results.txt
```

### Individual Commands
```bash
# Directed testbench simulation
iverilog -g2012 -o sim itch_lite_pkg.sv msg_decoder.sv msg_decoder_tb.sv && vvp sim
```
```bash
# Randomized testbench simulation (200 frames)
iverilog -g2012 -o sim_rand itch_lite_pkg.sv msg_decoder.sv msg_decoder_rand_tb.sv && vvp sim_rand
```
```bash
# Error and recovery testbench simulation
iverilog -g2012 -o sim_err itch_lite_pkg.sv msg_decoder.sv msg_decoder_error_tb.sv && vvp sim_err
```
```bash
# Verilator lint check
verilator --lint-only -Wall itch_lite_pkg.sv msg_decoder.sv
```
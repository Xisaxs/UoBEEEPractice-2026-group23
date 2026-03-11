# Plan: Command Processor (`cmdProc.vhd`) — Team A

Implement the `cmdProc` VHDL entity that bridges the UART link and the Data Processor. It parses keyboard commands from the UART RX, drives `start`/`numWords_bcd` to `dataConsume`, echoes incoming bytes as hex during data retrieval, and responds to `P`/`L` result commands via UART TX. The FSM runs at 100 MHz and communicates serially at 9600 baud.

---

## Provided Files (do not modify)

| File | Role |
|---|---|
| `common_pack.vhd` | Types (`BCD_ARRAY_TYPE`, `CHAR_ARRAY_TYPE`), constants, 500-byte data sequence |
| `UART_RX_CTRL.vhd` | 9600 baud RX, 100 MHz, 8N1 |
| `UART_TX_CTRL.vhd` | 9600 baud TX, 100 MHz, 8N1 |
| `dataGen.vhd` | 2-phase handshake data source |
| `top.vhd` | Structural top level — wires everything together |
| `cmdProcWrapper.vhd` | Blackbox wrapper for the reference synthesised netlist |
| `cmdProc_synthesised.vhd` | Reference implementation (synthesised netlist, for simulation only) |
| `dataConsumeWrapper.vhd` | Blackbox wrapper for Team B's Data Processor |
| `tb_CmdProcessor_Interim.vhd` | **Interim testbench** — tests `a012` / `A013` commands |
| `unsigned/tb_dataGenConsume_unsigned.vhd` | **Full integration testbench** — includes `L` and `P` commands |

---

## Interface: `cmdProc` Entity Ports

Declare the entity exactly as shown — port names and types must match `cmdProcWrapper.vhd`.

| Port | Dir | Type | Description |
|---|---|---|---|
| `clk` | in | `std_logic` | 100 MHz system clock |
| `reset` | in | `std_logic` | Synchronous active-high reset |
| `rxNow` | in | `std_logic` | High when RX has a new byte ready |
| `rxData` | in | `std_logic_vector(7 downto 0)` | Received byte from UART RX |
| `rxDone` | out | `std_logic` | Pulse high for **1 clock cycle** to acknowledge RX byte |
| `txData` | out | `std_logic_vector(7 downto 0)` | Byte to transmit via UART TX |
| `txNow` | out | `std_logic` | Pulse high for **1 clock cycle** to trigger TX |
| `txDone` | in | `std_logic` | High when TX is ready for the next byte |
| `ovErr` | in | `std_logic` | UART overrun error flag |
| `framErr` | in | `std_logic` | UART framing error flag |
| `start` | out | `std_logic` | Hold high throughout the entire data retrieval sequence |
| `numWords_bcd` | out | `BCD_ARRAY_TYPE(2 downto 0)` | BCD count: `(2)`=hundreds, `(1)`=tens, `(0)`=units |
| `dataReady` | in | `std_logic` | Pulsed high for 1 cycle by `dataConsume` when `byte` is valid |
| `byte` | in | `std_logic_vector(7 downto 0)` | Current data byte from `dataConsume` |
| `seqDone` | in | `std_logic` | Pulsed high for 1 cycle when the full sequence is done |
| `maxIndex` | in | `BCD_ARRAY_TYPE(2 downto 0)` | BCD index of peak byte; valid when `seqDone` is high |
| `dataResults` | in | `CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1)` | 7-byte window; `(3)` = peak; `(4..6)` = 3 before; `(0..2)` = 3 after |

---

## `dataResults` Index Convention

```
Index:  [6]   [5]   [4]   [3]   [2]   [1]   [0]
Role:  3 pre 2 pre 1 pre PEAK 1 post 2 post 3 post
```

- `dataResults(3)` is always the peak byte.
- `dataResults(4)` = the byte received 1 position before the peak.
- `dataResults(6)` = the byte received 3 positions before the peak (earliest).
- `dataResults(2)` = the byte received 1 position after the peak.
- `dataResults(0)` = the byte received 3 positions after the peak (latest).
- The `L` command should print in chronological order: `[6] [5] [4] [3] [2] [1] [0]`.

---

## Implementation Steps

### Step 1 — File skeleton
Create `cmdProc.vhd` in the `peak_detector/` folder. Add the library/use clauses for `IEEE.STD_LOGIC_1164`, `IEEE.NUMERIC_STD`, and `work.common_pack.all`. Declare the entity with the ports listed above.

### Step 2 — FSM state definition
Define a state type in the architecture. Suggested states (adjust as needed):

| State | Description |
|---|---|
| `IDLE` | Waiting for a character; echo every received char immediately |
| `GOT_A` | Received `A`/`a`; waiting for first decimal digit |
| `GOT_D1` | Received digit 1 of NNN |
| `GOT_D2` | Received digit 2 of NNN |
| `START_SEQ` | All 3 digits received; assert `start`, send `\n\r` |
| `STREAMING` | `start` held high; printing each `byte` as 2 hex chars on `dataReady` |
| `SEND_HEX_HIGH` | Sending high nibble ASCII hex character via TX |
| `SEND_HEX_LOW` | Sending low nibble ASCII hex character via TX |
| `WAIT_TX` | Waiting for `txDone` before sending the next character |
| `SEQ_DONE` | `seqDone` received; `start` deasserted; ready for `P`/`L` |
| `PRINT_PEAK` | Responding to `P`/`p`; send hex byte + space + decimal index |
| `PRINT_LIST` | Responding to `L`/`l`; send all 7 `dataResults` bytes as hex |

### Step 3 — Echo
In `IDLE`, when `rxNow = '1'`: latch `rxData`, pulse `rxDone` for 1 cycle, load `txData ← rxData`, pulse `txNow` for 1 cycle (wait for `txDone`). If `rxData` is `A`/`a` (`X"41"`/`X"61"`), transition to `GOT_A`.

### Step 4 — Command parsing (GOT_A → GOT_D1 → GOT_D2 → valid)
In `GOT_A`, `GOT_D1`, `GOT_D2`: on each `rxNow`, echo the character, then check if it is a decimal digit (`X"30"` to `X"39"`). If yes, latch the lower nibble into the corresponding BCD slot of `numWords_bcd` and advance state. If no, return to `IDLE` (reset digit accumulator). On receiving the third digit, transition to `START_SEQ`.

### Step 5 — Newline before output
Before printing any command output, always send `\n` (`X"0A"`) followed by `\r` (`X"0D"`). Use a small sub-FSM or counter to serialise the two-character sequence through TX.

### Step 6 — Asserting `start`
In `START_SEQ`: set `start <= '1'` and transition to `STREAMING`. Hold `start` high for the entire sequence — do **not** pulse it.

### Step 7 — Streaming data (`STREAMING`)
On each `dataReady` pulse: latch `byte`, then send the high nibble and low nibble as ASCII hex characters in sequence. Convert nibble `N` to ASCII: if `N < 10`, output `X"30" + N`; else output `X"37" + N` (i.e., `'A'` = `X"41"` = `X"37" + 10`). Wait for `txDone` between each character. On receiving `seqDone`: deassert `start`, latch `maxIndex` and `dataResults` into registers, transition to `SEQ_DONE`.

### Step 8 — UART TX protocol
`txNow` must be a **1-cycle pulse only**. Never assert `txNow` unless `txDone` (i.e., TX `READY`) is high. A safe pattern:
```
-- In a dedicated TX sub-state:
txData <= character_to_send;
txNow  <= '1';        -- for exactly 1 clock cycle
-- next cycle: txNow <= '0', wait for txDone to go high
```

### Step 9 — `P` / `p` command
In `SEQ_DONE`, if `rxNow` and `rxData = X"50"` or `X"70"`: send `\n\r`, then the peak byte (`dataResults(3)`) as 2 hex chars, then a space (`X"20"`), then `maxIndex` as up to 3 ASCII decimal characters (`(2)` hundreds, `(1)` tens, `(0)` units — each BCD nibble + `X"30"`).

### Step 10 — `L` / `l` command
In `SEQ_DONE`, if `rxNow` and `rxData = X"4C"` or `X"6C"`: send `\n\r`, then iterate through `dataResults` indices `6, 5, 4, 3, 2, 1, 0`, printing each as 2 hex chars (with a space separator between bytes, optional).

### Step 11 — Synchronous reset
On `reset = '1'` (clocked): return all registers and state to their initial values. Deassert `start`, `txNow`, `rxDone`. Clear `numWords_bcd`.

---

## UART RX Acknowledgement Pattern

Pulse `rxDone` high for **exactly 1 clock cycle** after latching `rxData`. Study `control_unit_tst.vhd` (`START_TRANSMIT` state) for the correct 1-cycle pulse pattern. The RX module clears its `dataReady` flag when it sees `rxDone` go high.

---

## UART TX Protocol

```
-- Correct TX send sequence:
-- 1. Check txDone = '1' (TX is ready)
-- 2. Set txData to the character
-- 3. Assert txNow = '1' for exactly 1 clock cycle
-- 4. Wait for txDone to return high before sending next character
```

Do **not** assert `txNow` if `txDone` is low. The transmitter will miss the byte.

---

## Key Constants (from `common_pack.vhd`)

| Constant | Value |
|---|---|
| `WORD_LENGTH` | 8 |
| `BCD_WORD_LENGTH` | 4 |
| `BCD_INDICES` | 3 |
| `RESULT_BYTE_NUM` | 7 |

---

## Verification Milestones

| Testbench | Command(s) | What is checked |
|---|---|---|
| `tb_CmdProcessor_Interim.vhd` | `a012`, `A013` | `start` asserted; correct byte count; TX outputs correct ASCII hex for first 12 bytes |
| `tb_dataGenConsume_unsigned.vhd` | `A012`, `A013`, `L`, `P` | Full unsigned integration; `L` prints 7 correct bytes; `P` prints correct peak + index |

### Expected unsigned results

| Command | Sequence | Expected TX output |
|---|---|---|
| `A012` | 12 bytes | Hex of bytes 0–11 printed sequentially |
| `P` after `A012` | — | Peak = `F9`, index = `7` |
| `L` after `A012` | — | `68 A8 93 F9 71 C7 92` |
| `P` after `A013` | — | Peak = `EB`, index = `5` |

---

## Corner Cases

- **Invalid command mid-sequence**: behaviour is undefined per spec; it is safe to ignore all RX input while `start` is high.
- **`P`/`L` before any sequence**: no output, no state change.
- **Multiple sequences**: `P`/`L` always refer to the most recent completed sequence; latch `dataResults` and `maxIndex` on `seqDone`.
- **`numWords_bcd = "000"`**: process 0 bytes; `seqDone` should arrive immediately.

---

## Submission Checklist

- [ ] `cmdProc.vhd` compiles without errors in Vivado simulator
- [ ] Passes `tb_CmdProcessor_Interim.vhd` (interim submission)
- [ ] Passes `tb_dataGenConsume_unsigned.vhd` (final submission)
- [ ] All `txNow` and `rxDone` pulses are exactly 1 clock cycle
- [ ] `start` is held high (not pulsed) for the full sequence
- [ ] Synchronous reset returns all state to initial values
- [ ] Source code included in submission archive with report

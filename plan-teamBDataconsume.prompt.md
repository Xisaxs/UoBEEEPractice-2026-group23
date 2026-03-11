# Plan: Data Processor (`dataConsume.vhd`) — Team B

Implement the `dataConsume` VHDL entity that drives the 2-phase handshake with `dataGen`, counts bytes, detects the peak (unsigned comparison), maintains a 7-byte sliding window around the peak, and signals results to `cmdProc` via `seqDone`, `dataResults`, and `maxIndex`. The FSM runs at 100 MHz.

---

## Provided Files (do not modify)

| File | Role |
|---|---|
| `common_pack.vhd` | Types (`BCD_ARRAY_TYPE`, `CHAR_ARRAY_TYPE`), constants, 500-byte data sequence |
| `dataGen.vhd` | 2-phase handshake data source (500 bytes, cycling) |
| `UART_RX_CTRL.vhd` | 9600 baud RX (used by integration testbench) |
| `UART_TX_CTRL.vhd` | 9600 baud TX (used by integration testbench) |
| `top.vhd` | Structural top level — wires everything together |
| `dataConsumeWrapper.vhd` | Blackbox wrapper for this module (defines the required port interface) |
| `unsigned/dataConsume_synthesised_unsigned.vhd` | Reference implementation — unsigned variant (simulation netlist) |
| `unsigned/tb_dataConsume_unsigned.vhd` | **Unit testbench** — direct drive, no UART, 6 sequences |
| `unsigned/tb_dataGenConsume_unsigned.vhd` | **Integration testbench** — full system with UART and cmdProc |

---

## Interface: `dataConsume` Entity Ports

Declare the entity exactly as shown — port names and types must match `dataConsumeWrapper.vhd`.

| Port | Dir | Type | Description |
|---|---|---|---|
| `clk` | in | `std_logic` | 100 MHz system clock |
| `reset` | in | `std_logic` | Synchronous active-high reset |
| `start` | in | `std_logic` | High = data retrieval active; low = halted |
| `numWords_bcd` | in | `BCD_ARRAY_TYPE(2 downto 0)` | BCD count of bytes to process: `(2)`=hundreds, `(1)`=tens, `(0)`=units |
| `ctrlIn` | in | `std_logic` | 2-phase handshake input from `dataGen` (any transition = data valid) |
| `ctrlOut` | out | `std_logic` | 2-phase handshake output to `dataGen` (any transition = request next byte) |
| `data` | in | `std_logic_vector(7 downto 0)` | 8-bit data byte from `dataGen`; valid when `ctrlIn` transition detected |
| `dataReady` | out | `std_logic` | Pulse high for **1 clock cycle** when `byte` output is valid |
| `byte` | out | `std_logic_vector(7 downto 0)` | Current data byte being forwarded to `cmdProc` |
| `seqDone` | out | `std_logic` | Pulse high for **1 clock cycle** when all `numWords` bytes processed |
| `maxIndex` | out | `BCD_ARRAY_TYPE(2 downto 0)` | BCD index of peak; `(2)`=hundreds, `(1)`=tens, `(0)`=units; valid from `seqDone` |
| `dataResults` | out | `CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1)` | 7-byte window; see layout below; valid from `seqDone` |

---

## `dataResults` Index Convention

```
Index:  [6]   [5]   [4]   [3]   [2]   [1]   [0]
Role:  3 pre 2 pre 1 pre PEAK 1 post 2 post 3 post
```

- `dataResults(3)` **must always** be the peak byte.
- `dataResults(4)` = byte received 1 position before the peak.
- `dataResults(5)` = byte received 2 positions before the peak.
- `dataResults(6)` = byte received 3 positions before the peak (earliest in time).
- `dataResults(2)` = byte received 1 position after the peak.
- `dataResults(1)` = byte received 2 positions after the peak.
- `dataResults(0)` = byte received 3 positions after the peak (latest in time).

> **Note:** The testbench assertion uses `dataResults(RESULT_BYTE_NUM-1-i) = RESULTS(seqCount)(i)`, which is equivalent to checking `dataResults(6-i)` against the expected array — keep this reversal in mind when comparing against expected values.

---

## 2-Phase Handshake Protocol with `dataGen`

The handshake is **non-return-to-zero**: any transition on a line (low→high or high→low) carries information. The `dataGen` module uses the same detection logic internally.

```
Sequence for acquiring one byte:
1. dataConsume: toggle ctrlOut  → requests a new byte from dataGen
2. dataGen:     places byte on data lines, toggles ctrlIn
3. dataConsume: detects transition on ctrlIn → latches data, valid!
4. (repeat from step 1 for next byte)
```

Transition detection on `ctrlIn`:
```vhdl
ctrlIn_delayed <= ctrlIn;  -- registered 1-cycle delay
ctrlIn_event   <= ctrlIn XOR ctrlIn_delayed;  -- '1' for exactly 1 cycle on any transition
```

Study `dataGen.vhd` — it uses exactly this pattern for `ctrlIn` detection.

---

## BCD Decoding

Convert `numWords_bcd` to a binary counter for countdown:

```vhdl
-- At the start of a sequence, load:
count <= (to_integer(unsigned(numWords_bcd(2))) * 100)
       + (to_integer(unsigned(numWords_bcd(1))) * 10)
       + (to_integer(unsigned(numWords_bcd(0))));
-- Decrement by 1 on each valid ctrlIn transition
-- Sequence is complete when count reaches 0
```

Maximum value: 999 → requires 10-bit counter (`2^10 = 1024 > 999`).

---

## Peak Detection

On each new byte received, use **unsigned** comparison: `unsigned(data) > unsigned(peak_reg)` — treat each byte as a plain 8-bit unsigned integer (0–255).

Rules:
- On the very first byte: unconditionally store it as the initial peak.
- On subsequent bytes: update only if the new byte is **strictly greater than** the current peak (retain the first occurrence on tie).
- On a new peak: record `maxIndex` (current byte index in BCD), snapshot the 3-entry pre-peak shift register into `dataResults(4..6)`, store the peak in `dataResults(3)`, and reset the post-peak counter.

---

## 7-Byte Sliding Window

Maintain a 3-entry shift register for the bytes arriving before the peak:

```vhdl
-- On every new byte, before peak comparison:
pre_buf(2) <= pre_buf(1);
pre_buf(1) <= pre_buf(0);
pre_buf(0) <= current_byte;
```

On a new peak event:
```vhdl
dataResults(6) <= pre_buf(2);  -- 3 bytes ago
dataResults(5) <= pre_buf(1);  -- 2 bytes ago
dataResults(4) <= pre_buf(0);  -- 1 byte ago
dataResults(3) <= current_byte; -- peak itself
post_count     <= 0;            -- reset post-peak counter
```

After a peak is recorded, collect the next 3 bytes arriving via handshake:
```vhdl
-- On each new byte while post_count < 3:
case post_count is
  when 0 => dataResults(2) <= current_byte;
  when 1 => dataResults(1) <= current_byte;
  when 2 => dataResults(0) <= current_byte;
end case;
post_count <= post_count + 1;
```

If a new (higher) peak arrives while `post_count < 3`, discard the partial post-window and restart.

---

## `maxIndex` BCD Encoding

Maintain the current byte index as a binary integer (`index_reg`). On a new peak, convert to BCD:

```vhdl
maxIndex(2) <= std_logic_vector(to_unsigned(index_reg / 100, 4));
maxIndex(1) <= std_logic_vector(to_unsigned((index_reg mod 100) / 10, 4));
maxIndex(0) <= std_logic_vector(to_unsigned(index_reg mod 10, 4));
```

`index_reg` counts from 0 for the first byte and increments by 1 per byte received.

---

## Implementation Steps

### Step 1 — File skeleton
Create `dataConsume.vhd` in `peak_detector/`. Add library/use clauses for `IEEE.STD_LOGIC_1164`, `IEEE.NUMERIC_STD`, and `work.common_pack.all`. Declare the entity with the ports above.

### Step 2 — Internal registers
Declare in the architecture:
- `ctrlIn_delayed : std_logic` — 1-cycle delayed `ctrlIn`
- `ctrlOut_reg : std_logic` — register driving `ctrlOut`
- `count : integer range 0 to 999` — countdown of bytes remaining
- `index_reg : integer range 0 to 999` — current byte index (0-based)
- `peak_reg : std_logic_vector(7 downto 0)` — stored peak value
- `pre_buf : CHAR_ARRAY_TYPE(0 to 2)` — 3-entry pre-peak shift register
- `post_count : integer range 0 to 3` — how many post-peak bytes collected
- `dataResults_reg : CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1)` — result window
- `maxIndex_reg : BCD_ARRAY_TYPE(2 downto 0)` — registered peak index
- `state : state_type` — FSM state

### Step 3 — FSM states

| State | Description |
|---|---|
| `IDLE` | Waiting for `start = '1'`; load `count` from `numWords_bcd` |
| `REQUEST` | Toggle `ctrlOut` to request first (or next) byte from `dataGen` |
| `WAIT_ACK` | Wait for a transition on `ctrlIn` (handshake acknowledge) |
| `LATCH` | Latch `data`, pulse `dataReady`, update peak/window, decrement `count` |
| `DONE` | Pulse `seqDone` for 1 cycle; hold results; return to `IDLE` |

### Step 4 — `ctrlIn` transition detection
Register `ctrlIn` on every clock edge. The XOR of `ctrlIn` and `ctrlIn_delayed` is `'1'` for exactly one clock cycle on any transition — this is the trigger to latch `data`.

### Step 5 — `start` semantics
Check `start` at the beginning of each clock cycle (it is a level, not a pulse). In `IDLE`, wait for `start = '1'` before doing anything. The `dataConsume` module should not fetch any bytes while `start = '0'`.

> The `cmdProc` module holds `start` high continuously during the entire sequence. `dataConsume` does not need to toggle `start` — it simply checks its level.

### Step 6 — `dataReady` and `byte` outputs
On the clock cycle following a valid `ctrlIn` transition (i.e., in state `LATCH`), drive `byte <= data` and pulse `dataReady <= '1'` for exactly 1 clock cycle. This allows `cmdProc` to capture the byte for hex printing.

### Step 7 — `seqDone`
When `count` reaches `1` and the last byte has been latched (i.e., processing the last byte in `LATCH`): transition to `DONE`, pulse `seqDone <= '1'` for exactly 1 clock cycle. Ensure `dataResults` and `maxIndex` are stable before `seqDone` goes high.

### Step 8 — Holding results
After `seqDone`, hold `dataResults_reg` and `maxIndex_reg` stable. Do not clear them until the next `start` rising level initiates a new sequence.

### Step 9 — Synchronous reset
On `reset = '1'` (clocked): return all registers and FSM state to initial values. Clear `ctrlOut_reg` to `'0'`, clear `peak_reg`, `count`, `index_reg`, `post_count`. Return state to `IDLE`.

---

## Key Constants (from `common_pack.vhd`)

| Constant | Value |
|---|---|
| `WORD_LENGTH` | 8 |
| `BCD_WORD_LENGTH` | 4 |
| `BCD_INDICES` | 3 |
| `RESULT_BYTE_NUM` | 7 |
| `SEQ_LENGTH` | 500 |

---

## Verification Milestones

### Unit testbench (`tb_dataConsume_unsigned.vhd`)
Drives `start`, `numWords_bcd` directly — no UART involved. Runs 6 sequences. On each `seqDone`, checks `dataResults` and `maxIndex` against a table of expected values.

**Expected unsigned results:**

| Run | `numWords` | Expected `dataResults[6..0]` | `maxIndex` |
|---|---|---|---|
| 0 | 500 | `F0 7B 92 FE 68 39 DD` | `228` |
| 1 | 100 | `56 4E D1 FB F8 94 3C` | `081` |

### Integration testbench (`tb_dataGenConsume_unsigned.vhd`)
Full system: UART RX → `cmdProc` → `dataConsume` → `dataGen`. Commands `A012`, `A013`, `L`, `P`. Simulate for ≥ 250 ms.

**Expected unsigned integration results:**

| Sequence | Peak | Index |
|---|---|---|
| 12 bytes | `X"F9"` (249 unsigned) | 7 |
| 13 bytes | `X"EB"` (235 unsigned) | 5 |

---

## Corner Cases

- **Peak at index 0–2**: fewer than 3 valid bytes before the peak. The `pre_buf` entries for positions that have not been filled will contain whatever their reset/initial value is — this is acceptable per the spec (only valid entries need be correct).
- **Peak near the end of the sequence**: fewer than 3 bytes available after the peak. `dataResults(0)` and/or `dataResults(1)` may not be populated — also acceptable per spec.
- **`numWords = "000"`**: the sequence has 0 bytes. `seqDone` should fire immediately (or on the first clock cycle after `start`). Handle this as a special case: if `count = 0` after loading, go directly to `DONE`.
- **Multiple peaks at the same value**: only the **first** occurrence is retained (strictly-greater-than comparison, not greater-than-or-equal).
- **Sequence length > 500**: `dataGen` wraps around at byte 500 back to byte 0. `dataConsume` does not need to track this — it simply counts `numWords` bytes.

---

## Submission Checklist

- [ ] `dataConsume.vhd` compiles without errors in Vivado simulator
- [ ] Passes `tb_dataConsume_unsigned.vhd` (unit test, all 6 sequences)
- [ ] Passes `tb_dataGenConsume_unsigned.vhd` (full integration)
- [ ] `dataReady` and `seqDone` are exactly 1-cycle pulses
- [ ] `ctrlOut` toggles correctly (2-phase, not level-driven)
- [ ] `dataResults(3)` always contains the peak byte
- [ ] Unsigned comparison (`unsigned(data) > unsigned(peak_reg)`) implemented correctly
- [ ] Synchronous reset returns all state to initial values
- [ ] Source code included in submission archive with report
- [ ] Signed or unsigned comparison matches group assignment
- [ ] Synchronous reset returns all state to initial values
- [ ] Source code included in submission archive with report

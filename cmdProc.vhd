library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.common_pack.all;

entity cmdProc is
  port (
    clk:          in std_logic;
    reset:        in std_logic;
    rxnow:        in std_logic;
    rxData:       in std_logic_vector (7 downto 0);
    txData:       out std_logic_vector (7 downto 0);
    rxdone:       out std_logic;
    ovErr:        in std_logic;
    framErr:      in std_logic;
    txnow:        out std_logic;
    txdone:       in std_logic;
    start:        out std_logic;
    numWords_bcd: out BCD_ARRAY_TYPE(2 downto 0);
    dataReady:    in std_logic;
    byte:         in std_logic_vector(7 downto 0);
    maxIndex:     in BCD_ARRAY_TYPE(2 downto 0);
    dataResults:  in CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1);
    seqDone:      in std_logic
  );
end cmdProc;

architecture rtl of cmdProc is

  type state_type is (
    IDLE,
    ECHO_TX,
    ECHO_TX_WAIT,
    RUN_NL_LF,
    RUN_NL_LF_WAIT,
    RUN_NL_CR,
    RUN_NL_CR_WAIT,
    RUN_REQ,
    RUN_TX_HI,
    RUN_TX_HI_WAIT,
    RUN_TX_LO,
    RUN_TX_LO_WAIT,
    RUN_TX_SEP,
    RUN_TX_SEP_WAIT,
    LIST_NL_LF,
    LIST_NL_LF_WAIT,
    LIST_NL_CR,
    LIST_NL_CR_WAIT,
    LIST_TX_HI,
    LIST_TX_HI_WAIT,
    LIST_TX_LO,
    LIST_TX_LO_WAIT,
    LIST_TX_SEP,
    LIST_TX_SEP_WAIT,
    PEAK_NL_LF,
    PEAK_NL_LF_WAIT,
    PEAK_NL_CR,
    PEAK_NL_CR_WAIT,
    PEAK_TX_HI,
    PEAK_TX_HI_WAIT,
    PEAK_TX_LO,
    PEAK_TX_LO_WAIT,
    PEAK_TX_SPACE,
    PEAK_TX_SPACE_WAIT,
    PEAK_TX_I2,
    PEAK_TX_I2_WAIT,
    PEAK_TX_I1,
    PEAK_TX_I1_WAIT,
    PEAK_TX_I0,
    PEAK_TX_I0_WAIT
  );

  constant ASCII_A_UC: std_logic_vector(7 downto 0) := x"41";
  constant ASCII_A_LC: std_logic_vector(7 downto 0) := x"61";
  constant ASCII_L_UC: std_logic_vector(7 downto 0) := x"4C";
  constant ASCII_L_LC: std_logic_vector(7 downto 0) := x"6C";
  constant ASCII_P_UC: std_logic_vector(7 downto 0) := x"50";
  constant ASCII_P_LC: std_logic_vector(7 downto 0) := x"70";
  constant ASCII_0:    std_logic_vector(7 downto 0) := x"30";
  constant ASCII_9:    std_logic_vector(7 downto 0) := x"39";
  constant ASCII_LF:   std_logic_vector(7 downto 0) := x"0A";
  constant ASCII_CR:   std_logic_vector(7 downto 0) := x"0D";
  constant ASCII_SPC:  std_logic_vector(7 downto 0) := x"20";

  signal curState: state_type := IDLE;
  signal nextState:    state_type := IDLE;

  signal rxWin0: std_logic_vector(7 downto 0) := (others => '0');
  signal rxWin1: std_logic_vector(7 downto 0) := (others => '0');
  signal rxWin2: std_logic_vector(7 downto 0) := (others => '0');
  signal rxWin3: std_logic_vector(7 downto 0) := (others => '0');

  signal start_evt: std_logic := '0';
  signal list_evt:  std_logic := '0';
  signal peak_evt:  std_logic := '0';
  signal echo_pending: std_logic := '0';
  signal echo_byte: std_logic_vector(7 downto 0) := (others => '0');
  signal numWords_reg: BCD_ARRAY_TYPE(2 downto 0) := (others => (others => '0'));
  signal runByteReg: std_logic_vector(7 downto 0) := (others => '0');
  signal result_bytes_reg: CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1) := (others => (others => '0'));
  signal peak_index_reg: BCD_ARRAY_TYPE(2 downto 0) := (others => (others => '0'));
  signal result_valid: std_logic := '0';
  signal list_idx: integer range 0 to RESULT_BYTE_NUM-1 := 0;
  signal seqDone_latched: std_logic := '0';

  function is_digit(c: std_logic_vector(7 downto 0)) return boolean is
  begin
    return (unsigned(c) >= unsigned(ASCII_0)) and (unsigned(c) <= unsigned(ASCII_9));
  end function;

  function ascii_to_bcd(c: std_logic_vector(7 downto 0)) return std_logic_vector is
    variable d: unsigned(7 downto 0);
  begin
    d := unsigned(c) - unsigned(ASCII_0);
    return std_logic_vector(d(3 downto 0));
  end function;

  function nibble_to_ascii(nib: std_logic_vector(3 downto 0)) return std_logic_vector is
    variable u: unsigned(3 downto 0);
  begin
    u := unsigned(nib);
    if u <= 9 then
      return std_logic_vector(to_unsigned(48 + to_integer(u), 8));
    else
      return std_logic_vector(to_unsigned(55 + to_integer(u), 8));
    end if;
  end function;

  function bcd_to_ascii(dig: std_logic_vector(3 downto 0)) return std_logic_vector is
    variable u: unsigned(3 downto 0);
  begin
    u := unsigned(dig);
    if u <= 9 then
      return std_logic_vector(to_unsigned(48 + to_integer(u), 8));
    else
      return x"3F";
    end if;
  end function;

  function in_run_phase(st: state_type) return boolean is
  begin
    case st is
      when RUN_REQ | RUN_TX_HI | RUN_TX_HI_WAIT | RUN_TX_LO | RUN_TX_LO_WAIT | RUN_TX_SEP | RUN_TX_SEP_WAIT =>
        return true;
      when others =>
        return false;
    end case;
  end function;

begin

  state_reg: process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        curState <= IDLE;
      else
        curState <= nextState;
      end if;
    end if;
  end process;

  rx_parser_regs: process(clk)
    variable n0: std_logic_vector(7 downto 0);
    variable n1: std_logic_vector(7 downto 0);
    variable n2: std_logic_vector(7 downto 0);
    variable n3: std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      if reset = '1' then
        rxWin0 <= (others => '0');
        rxWin1 <= (others => '0');
        rxWin2 <= (others => '0');
        rxWin3 <= (others => '0');
        start_evt <= '0';
        list_evt <= '0';
        peak_evt <= '0';
        echo_pending <= '0';
        echo_byte <= (others => '0');
        numWords_reg <= (others => (others => '0'));
        result_valid <= '0';
        list_idx <= 0;
        runByteReg <= (others => '0');
        result_bytes_reg <= (others => (others => '0'));
        peak_index_reg <= (others => (others => '0'));
        seqDone_latched <= '0';
      else
        -- Maintain command/event registers directly from current FSM state.
        if curState = RUN_NL_LF then
          start_evt <= '0';
        end if;
        if curState = LIST_NL_LF then
          list_evt <= '0';
        end if;
        if curState = PEAK_NL_LF then
          peak_evt <= '0';
        end if;
        if curState = ECHO_TX then
          echo_pending <= '0';
        end if;

        if curState = RUN_NL_LF then
          result_valid <= '0';
        elsif (curState = RUN_REQ) and (seqDone_latched = '1') then
          result_valid <= '1';
        end if;

        if curState = RUN_NL_LF then
          seqDone_latched <= '0';
        elsif (seqDone = '1') and in_run_phase(curState) then
          seqDone_latched <= '1';
        end if;

        if curState = LIST_NL_LF then
          list_idx <= 0;
        elsif (curState = LIST_TX_SEP_WAIT) and (txdone = '1') and (list_idx < RESULT_BYTE_NUM-1) then
          list_idx <= list_idx + 1;
        end if;

        if (curState = RUN_REQ) and (dataReady = '1') then
          runByteReg <= byte;
        end if;

        if seqDone = '1' then
          result_bytes_reg <= dataResults;
          peak_index_reg <= maxIndex;
        end if;

        if rxnow = '1' then
          n0 := rxWin1;
          n1 := rxWin2;
          n2 := rxWin3;
          n3 := rxData;

          rxWin0 <= n0;
          rxWin1 <= n1;
          rxWin2 <= n2;
          rxWin3 <= n3;

          echo_byte <= rxData;
          echo_pending <= '1';

          if curState = IDLE then
            if ((n0 = ASCII_A_UC) or (n0 = ASCII_A_LC)) and is_digit(n1) and is_digit(n2) and is_digit(n3) then
              numWords_reg(2) <= ascii_to_bcd(n1);
              numWords_reg(1) <= ascii_to_bcd(n2);
              numWords_reg(0) <= ascii_to_bcd(n3);
              start_evt <= '1';
            elsif (n3 = ASCII_L_UC) or (n3 = ASCII_L_LC) then
              if result_valid = '1' then
                list_evt <= '1';
              end if;
            elsif (n3 = ASCII_P_UC) or (n3 = ASCII_P_LC) then
              if result_valid = '1' then
                peak_evt <= '1';
              end if;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  next_state_logic: process(curState, start_evt, list_evt, peak_evt, echo_pending, result_valid, dataReady, seqDone_latched, txdone, list_idx)
  begin
    nextState <= curState;

    case curState is
      when IDLE =>
        if echo_pending = '1' then
          nextState <= ECHO_TX;
        elsif start_evt = '1' then
          nextState <= RUN_NL_LF;
        elsif (list_evt = '1') and (result_valid = '1') then
          nextState <= LIST_NL_LF;
        elsif (peak_evt = '1') and (result_valid = '1') then
          nextState <= PEAK_NL_LF;
        end if;

      when ECHO_TX =>
        nextState <= ECHO_TX_WAIT;

      when ECHO_TX_WAIT =>
        if txdone = '1' then
          nextState <= IDLE;
        end if;

      when RUN_NL_LF =>
        nextState <= RUN_NL_LF_WAIT;

      when RUN_NL_LF_WAIT =>
        if txdone = '1' then
          nextState <= RUN_NL_CR;
        end if;

      when RUN_NL_CR =>
        nextState <= RUN_NL_CR_WAIT;

      when RUN_NL_CR_WAIT =>
        if txdone = '1' then
          nextState <= RUN_REQ;
        end if;

      when RUN_REQ =>
        if seqDone_latched = '1' then
          nextState <= IDLE;
        elsif dataReady = '1' then
          nextState <= RUN_TX_HI;
        end if;

      when RUN_TX_HI =>
        nextState <= RUN_TX_HI_WAIT;

      when RUN_TX_HI_WAIT =>
        if txdone = '1' then
          nextState <= RUN_TX_LO;
        end if;

      when RUN_TX_LO =>
        nextState <= RUN_TX_LO_WAIT;

      when RUN_TX_LO_WAIT =>
        if txdone = '1' then
          nextState <= RUN_TX_SEP;
        end if;

      when RUN_TX_SEP =>
        nextState <= RUN_TX_SEP_WAIT;

      when RUN_TX_SEP_WAIT =>
        if txdone = '1' then
          nextState <= RUN_REQ;
        end if;

      when LIST_NL_LF =>
        nextState <= LIST_NL_LF_WAIT;

      when LIST_NL_LF_WAIT =>
        if txdone = '1' then
          nextState <= LIST_NL_CR;
        end if;

      when LIST_NL_CR =>
        nextState <= LIST_NL_CR_WAIT;

      when LIST_NL_CR_WAIT =>
        if txdone = '1' then
          nextState <= LIST_TX_HI;
        end if;

      when LIST_TX_HI =>
        nextState <= LIST_TX_HI_WAIT;

      when LIST_TX_HI_WAIT =>
        if txdone = '1' then
          nextState <= LIST_TX_LO;
        end if;

      when LIST_TX_LO =>
        nextState <= LIST_TX_LO_WAIT;

      when LIST_TX_LO_WAIT =>
        if txdone = '1' then
          nextState <= LIST_TX_SEP;
        end if;

      when LIST_TX_SEP =>
        nextState <= LIST_TX_SEP_WAIT;

      when LIST_TX_SEP_WAIT =>
        if txdone = '1' then
          if list_idx = RESULT_BYTE_NUM-1 then
            nextState <= IDLE;
          else
            nextState <= LIST_TX_HI;
          end if;
        end if;

      when PEAK_NL_LF =>
        nextState <= PEAK_NL_LF_WAIT;

      when PEAK_NL_LF_WAIT =>
        if txdone = '1' then
          nextState <= PEAK_NL_CR;
        end if;

      when PEAK_NL_CR =>
        nextState <= PEAK_NL_CR_WAIT;

      when PEAK_NL_CR_WAIT =>
        if txdone = '1' then
          nextState <= PEAK_TX_HI;
        end if;

      when PEAK_TX_HI =>
        nextState <= PEAK_TX_HI_WAIT;

      when PEAK_TX_HI_WAIT =>
        if txdone = '1' then
          nextState <= PEAK_TX_LO;
        end if;

      when PEAK_TX_LO =>
        nextState <= PEAK_TX_LO_WAIT;

      when PEAK_TX_LO_WAIT =>
        if txdone = '1' then
          nextState <= PEAK_TX_SPACE;
        end if;

      when PEAK_TX_SPACE =>
        nextState <= PEAK_TX_SPACE_WAIT;

      when PEAK_TX_SPACE_WAIT =>
        if txdone = '1' then
          nextState <= PEAK_TX_I2;
        end if;

      when PEAK_TX_I2 =>
        nextState <= PEAK_TX_I2_WAIT;

      when PEAK_TX_I2_WAIT =>
        if txdone = '1' then
          nextState <= PEAK_TX_I1;
        end if;

      when PEAK_TX_I1 =>
        nextState <= PEAK_TX_I1_WAIT;

      when PEAK_TX_I1_WAIT =>
        if txdone = '1' then
          nextState <= PEAK_TX_I0;
        end if;

      when PEAK_TX_I0 =>
        nextState <= PEAK_TX_I0_WAIT;

      when PEAK_TX_I0_WAIT =>
        if txdone = '1' then
          nextState <= IDLE;
        end if;

      when others =>
        nextState <= IDLE;
    end case;
  end process;

  output_logic: process(curState, rxnow, dataReady, seqDone_latched, runByteReg, numWords_reg, list_idx, result_bytes_reg, peak_index_reg, echo_byte)
  begin
    txData <= (others => '1');
    txnow <= '0';
    rxdone <= '0';
    start <= '0';
    numWords_bcd <= numWords_reg;

    if rxnow = '1' then
      rxdone <= '1';
    end if;

    case curState is
      when IDLE =>
        null;

      when ECHO_TX =>
        txData <= echo_byte;
        txnow <= '1';

      when ECHO_TX_WAIT =>
        null;

      when RUN_NL_LF =>
        txData <= ASCII_LF;
        txnow <= '1';

      when RUN_NL_LF_WAIT =>
        null;

      when RUN_NL_CR =>
        txData <= ASCII_CR;
        txnow <= '1';

      when RUN_NL_CR_WAIT =>
        null;

      when RUN_REQ =>
        if (seqDone_latched = '0') and (dataReady = '0') then
          start <= '1';
        else
          start <= '0';
        end if;

      when RUN_TX_HI =>
        txData <= nibble_to_ascii(runByteReg(7 downto 4));
        txnow <= '1';

      when RUN_TX_HI_WAIT =>
        null;

      when RUN_TX_LO =>
        txData <= nibble_to_ascii(runByteReg(3 downto 0));
        txnow <= '1';

      when RUN_TX_LO_WAIT =>
        null;

      when RUN_TX_SEP =>
        txData <= ASCII_SPC;
        txnow <= '1';

      when RUN_TX_SEP_WAIT =>
        null;

      when LIST_NL_LF =>
        txData <= ASCII_LF;
        txnow <= '1';

      when LIST_NL_LF_WAIT =>
        null;

      when LIST_NL_CR =>
        txData <= ASCII_CR;
        txnow <= '1';

      when LIST_NL_CR_WAIT =>
        null;

      when LIST_TX_HI =>
        txData <= nibble_to_ascii(result_bytes_reg(list_idx)(7 downto 4));
        txnow <= '1';

      when LIST_TX_HI_WAIT =>
        null;

      when LIST_TX_LO =>
        txData <= nibble_to_ascii(result_bytes_reg(list_idx)(3 downto 0));
        txnow <= '1';

      when LIST_TX_LO_WAIT =>
        null;

      when LIST_TX_SEP =>
        txData <= ASCII_SPC;
        txnow <= '1';

      when LIST_TX_SEP_WAIT =>
        null;

      when PEAK_NL_LF =>
        txData <= ASCII_LF;
        txnow <= '1';

      when PEAK_NL_LF_WAIT =>
        null;

      when PEAK_NL_CR =>
        txData <= ASCII_CR;
        txnow <= '1';

      when PEAK_NL_CR_WAIT =>
        null;

      when PEAK_TX_HI =>
        txData <= nibble_to_ascii(result_bytes_reg(3)(7 downto 4));
        txnow <= '1';

      when PEAK_TX_HI_WAIT =>
        null;

      when PEAK_TX_LO =>
        txData <= nibble_to_ascii(result_bytes_reg(3)(3 downto 0));
        txnow <= '1';

      when PEAK_TX_LO_WAIT =>
        null;

      when PEAK_TX_SPACE =>
        txData <= ASCII_SPC;
        txnow <= '1';

      when PEAK_TX_SPACE_WAIT =>
        null;

      when PEAK_TX_I2 =>
        txData <= bcd_to_ascii(peak_index_reg(2));
        txnow <= '1';

      when PEAK_TX_I2_WAIT =>
        null;

      when PEAK_TX_I1 =>
        txData <= bcd_to_ascii(peak_index_reg(1));
        txnow <= '1';

      when PEAK_TX_I1_WAIT =>
        null;

      when PEAK_TX_I0 =>
        txData <= bcd_to_ascii(peak_index_reg(0));
        txnow <= '1';

      when PEAK_TX_I0_WAIT =>
        null;

      when others =>
        null;
    end case;
  end process;

end rtl;



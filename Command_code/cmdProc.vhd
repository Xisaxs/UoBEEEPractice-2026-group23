library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
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

architecture Behavioral of cmdProc is

    type state_type is (
        IDLE,
        GOT_A,
        GOT_D1,
        GOT_D2,
        SEND_ECHO,
        SEND_LF,
        SEND_CR,
        START_SEQ,
        STREAM_WAIT,
        STREAM_HEX_HIGH,
        STREAM_HEX_LOW,
        STREAM_SPACE,
        RESULTS_WAIT,
        PRINT_P_HEX_HIGH,
        PRINT_P_HEX_LOW,
        PRINT_P_SPACE,
        PRINT_P_HUND,
        PRINT_P_TENS,
        PRINT_P_ONES,
        PRINT_L_INIT,
        PRINT_L_HEX_HIGH,
        PRINT_L_HEX_LOW,
        PRINT_L_SPACE
    );

    function is_ascii_digit(ch : std_logic_vector(7 downto 0)) return boolean is
    begin
        return (unsigned(ch) >= to_unsigned(16#30#, 8)) and
               (unsigned(ch) <= to_unsigned(16#39#, 8));
    end function;

    function is_start_cmd(ch : std_logic_vector(7 downto 0)) return boolean is
    begin
        return (ch = X"41") or (ch = X"61");
    end function;

    function is_peak_cmd(ch : std_logic_vector(7 downto 0)) return boolean is
    begin
        return (ch = X"50") or (ch = X"70");
    end function;

    function is_list_cmd(ch : std_logic_vector(7 downto 0)) return boolean is
    begin
        return (ch = X"4C") or (ch = X"6C");
    end function;

    function nibble_to_ascii(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
        variable nibble_u : unsigned(3 downto 0);
        variable ascii_u  : unsigned(7 downto 0);
    begin
        nibble_u := unsigned(nibble);
        if nibble_u < 10 then
            ascii_u := to_unsigned(16#30#, 8) + resize(nibble_u, 8);
        else
            ascii_u := to_unsigned(16#37#, 8) + resize(nibble_u, 8);
        end if;
        return std_logic_vector(ascii_u);
    end function;

    function bcd_to_ascii(digit : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(16#30#, 8) + resize(unsigned(digit), 8));
    end function;

    signal state              : state_type := IDLE;
    signal next_after_echo    : state_type := IDLE;
    signal next_after_newline : state_type := IDLE;

    signal rxDone_reg         : std_logic := '0';
    signal txNow_reg          : std_logic := '0';
    signal txData_reg         : std_logic_vector(7 downto 0) := (others => '0');
    signal start_reg          : std_logic := '0';

    signal numWords_reg       : BCD_ARRAY_TYPE(2 downto 0) := (others => (others => '0'));
    signal stream_byte_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal echo_char_reg      : std_logic_vector(7 downto 0) := (others => '0');

    signal maxIndex_reg       : BCD_ARRAY_TYPE(2 downto 0) := (others => (others => '0'));
    signal dataResults_reg    : CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1) := (others => (others => '0'));

    signal have_results       : std_logic := '0';
    signal seq_done_pending   : std_logic := '0';

    signal list_idx           : integer range 0 to RESULT_BYTE_NUM-1 := 0;
    signal p_sent_nonzero     : std_logic := '0';

begin

    txData <= txData_reg;
    txNow <= txNow_reg;
    rxDone <= rxDone_reg;
    start <= start_reg;
    numWords_bcd <= numWords_reg;

    process(clk)
    begin
        if rising_edge(clk) then
            txNow_reg <= '0';
            rxDone_reg <= '0';

            if reset = '1' then
                state <= IDLE;
                next_after_echo <= IDLE;
                next_after_newline <= IDLE;
                rxDone_reg <= '0';
                txNow_reg <= '0';
                txData_reg <= (others => '0');
                start_reg <= '0';
                numWords_reg <= (others => (others => '0'));
                stream_byte_reg <= (others => '0');
                echo_char_reg <= (others => '0');
                maxIndex_reg <= (others => (others => '0'));
                dataResults_reg <= (others => (others => '0'));
                have_results <= '0';
                seq_done_pending <= '0';
                list_idx <= 0;
                p_sent_nonzero <= '0';
            else
                case state is
                    when IDLE =>
                        start_reg <= '0';

                        if rxNow = '1' then
                            echo_char_reg <= rxData;
                            rxDone_reg <= '1';

                            if is_start_cmd(rxData) then
                                numWords_reg <= (others => (others => '0'));
                                next_after_echo <= GOT_A;
                            else
                                next_after_echo <= IDLE;
                            end if;

                            state <= SEND_ECHO;
                        end if;

                    when GOT_A =>
                        if rxNow = '1' then
                            echo_char_reg <= rxData;
                            rxDone_reg <= '1';

                            if is_ascii_digit(rxData) then
                                numWords_reg(2) <= rxData(3 downto 0);
                                next_after_echo <= GOT_D1;
                            elsif is_start_cmd(rxData) then
                                numWords_reg <= (others => (others => '0'));
                                next_after_echo <= GOT_A;
                            else
                                numWords_reg <= (others => (others => '0'));
                                next_after_echo <= IDLE;
                            end if;

                            state <= SEND_ECHO;
                        end if;

                    when GOT_D1 =>
                        if rxNow = '1' then
                            echo_char_reg <= rxData;
                            rxDone_reg <= '1';

                            if is_ascii_digit(rxData) then
                                numWords_reg(1) <= rxData(3 downto 0);
                                next_after_echo <= GOT_D2;
                            elsif is_start_cmd(rxData) then
                                numWords_reg <= (others => (others => '0'));
                                next_after_echo <= GOT_A;
                            else
                                numWords_reg <= (others => (others => '0'));
                                next_after_echo <= IDLE;
                            end if;

                            state <= SEND_ECHO;
                        end if;

                    when GOT_D2 =>
                        if rxNow = '1' then
                            echo_char_reg <= rxData;
                            rxDone_reg <= '1';

                            if is_ascii_digit(rxData) then
                                numWords_reg(0) <= rxData(3 downto 0);
                                next_after_newline <= START_SEQ;
                                next_after_echo <= SEND_LF;
                            elsif is_start_cmd(rxData) then
                                numWords_reg <= (others => (others => '0'));
                                next_after_echo <= GOT_A;
                            else
                                numWords_reg <= (others => (others => '0'));
                                next_after_echo <= IDLE;
                            end if;

                            state <= SEND_ECHO;
                        end if;

                    when SEND_ECHO =>
                        if txDone = '1' then
                            txData_reg <= echo_char_reg;
                            txNow_reg <= '1';
                            state <= next_after_echo;
                        end if;

                    when SEND_LF =>
                        if txDone = '1' then
                            txData_reg <= X"0A";
                            txNow_reg <= '1';
                            state <= SEND_CR;
                        end if;

                    when SEND_CR =>
                        if txDone = '1' then
                            txData_reg <= X"0D";
                            txNow_reg <= '1';
                            state <= next_after_newline;
                        end if;

                    when START_SEQ =>
                        start_reg <= '1';
                        have_results <= '0';
                        seq_done_pending <= '0';
                        p_sent_nonzero <= '0';
                        state <= STREAM_WAIT;

                    when STREAM_WAIT =>
                        start_reg <= '1';

                        if dataReady = '1' then
                            stream_byte_reg <= byte;

                            if seqDone = '1' then
                                maxIndex_reg <= maxIndex;
                                dataResults_reg <= dataResults;
                                seq_done_pending <= '1';
                            end if;

                            state <= STREAM_HEX_HIGH;
                        elsif seqDone = '1' then
                            start_reg <= '0';
                            maxIndex_reg <= maxIndex;
                            dataResults_reg <= dataResults;
                            have_results <= '1';
                            seq_done_pending <= '0';
                            state <= RESULTS_WAIT;
                        end if;

                    when STREAM_HEX_HIGH =>
                        start_reg <= '1';

                        if txDone = '1' then
                            txData_reg <= nibble_to_ascii(stream_byte_reg(7 downto 4));
                            txNow_reg <= '1';
                            state <= STREAM_HEX_LOW;
                        end if;

                    when STREAM_HEX_LOW =>
                        start_reg <= '1';

                        if txDone = '1' then
                            txData_reg <= nibble_to_ascii(stream_byte_reg(3 downto 0));
                            txNow_reg <= '1';
                            state <= STREAM_SPACE;
                        end if;

                    when STREAM_SPACE =>
                        start_reg <= '1';

                        if txDone = '1' then
                            txData_reg <= X"20";
                            txNow_reg <= '1';

                            if seq_done_pending = '1' then
                                start_reg <= '0';
                                have_results <= '1';
                                seq_done_pending <= '0';
                                state <= RESULTS_WAIT;
                            else
                                state <= STREAM_WAIT;
                            end if;
                        end if;

                    when RESULTS_WAIT =>
                        start_reg <= '0';

                        if rxNow = '1' then
                            echo_char_reg <= rxData;
                            rxDone_reg <= '1';

                            if is_start_cmd(rxData) then
                                numWords_reg <= (others => (others => '0'));
                                next_after_echo <= GOT_A;
                            elsif have_results = '1' and is_peak_cmd(rxData) then
                                p_sent_nonzero <= '0';
                                next_after_newline <= PRINT_P_HEX_HIGH;
                                next_after_echo <= SEND_LF;
                            elsif have_results = '1' and is_list_cmd(rxData) then
                                list_idx <= RESULT_BYTE_NUM - 1;
                                next_after_newline <= PRINT_L_INIT;
                                next_after_echo <= SEND_LF;
                            else
                                next_after_echo <= RESULTS_WAIT;
                            end if;

                            state <= SEND_ECHO;
                        end if;

                    when PRINT_P_HEX_HIGH =>
                        if txDone = '1' then
                            txData_reg <= nibble_to_ascii(dataResults_reg(3)(7 downto 4));
                            txNow_reg <= '1';
                            state <= PRINT_P_HEX_LOW;
                        end if;

                    when PRINT_P_HEX_LOW =>
                        if txDone = '1' then
                            txData_reg <= nibble_to_ascii(dataResults_reg(3)(3 downto 0));
                            txNow_reg <= '1';
                            state <= PRINT_P_SPACE;
                        end if;

                    when PRINT_P_SPACE =>
                        if txDone = '1' then
                            txData_reg <= X"20";
                            txNow_reg <= '1';
                            p_sent_nonzero <= '0';
                            state <= PRINT_P_HUND;
                        end if;

                    when PRINT_P_HUND =>
                        if maxIndex_reg(2) /= X"0" then
                            if txDone = '1' then
                                txData_reg <= bcd_to_ascii(maxIndex_reg(2));
                                txNow_reg <= '1';
                                p_sent_nonzero <= '1';
                                state <= PRINT_P_TENS;
                            end if;
                        else
                            state <= PRINT_P_TENS;
                        end if;

                    when PRINT_P_TENS =>
                        if (p_sent_nonzero = '1') or (maxIndex_reg(1) /= X"0") then
                            if txDone = '1' then
                                txData_reg <= bcd_to_ascii(maxIndex_reg(1));
                                txNow_reg <= '1';
                                p_sent_nonzero <= '1';
                                state <= PRINT_P_ONES;
                            end if;
                        else
                            state <= PRINT_P_ONES;
                        end if;

                    when PRINT_P_ONES =>
                        if txDone = '1' then
                            txData_reg <= bcd_to_ascii(maxIndex_reg(0));
                            txNow_reg <= '1';
                            state <= RESULTS_WAIT;
                        end if;

                    when PRINT_L_INIT =>
                        state <= PRINT_L_HEX_HIGH;

                    when PRINT_L_HEX_HIGH =>
                        if txDone = '1' then
                            txData_reg <= nibble_to_ascii(dataResults_reg(list_idx)(7 downto 4));
                            txNow_reg <= '1';
                            state <= PRINT_L_HEX_LOW;
                        end if;

                    when PRINT_L_HEX_LOW =>
                        if txDone = '1' then
                            txData_reg <= nibble_to_ascii(dataResults_reg(list_idx)(3 downto 0));
                            txNow_reg <= '1';

                            if list_idx = 0 then
                                state <= RESULTS_WAIT;
                            else
                                state <= PRINT_L_SPACE;
                            end if;
                        end if;

                    when PRINT_L_SPACE =>
                        if txDone = '1' then
                            txData_reg <= X"20";
                            txNow_reg <= '1';
                            list_idx <= list_idx - 1;
                            state <= PRINT_L_HEX_HIGH;
                        end if;

                    when others =>
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process;

end Behavioral;

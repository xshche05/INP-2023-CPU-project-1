-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2023 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): jmeno <login AT stud.fit.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------

entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (0) / zapis (1)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_WE   : out std_logic;                      -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

   -- stavove signaly
   READY    : out std_logic;                      -- hodnota 1 znamena, ze byl procesor inicializovan a zacina vykonavat program
   DONE     : out std_logic                       -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
 );
end cpu;

-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is
  signal PTR : std_logic_vector(12 downto 0) := "0000000000000"; -- pointer register
  signal PC : std_logic_vector(12 downto 0) := "0000000000000";  -- program counter register
  signal CNT : std_logic_vector(7 downto 0) := "00000000"; -- while counter

  signal mx1_sel : std_logic; -- address multiplexer selector
  signal mx2_sel : std_logic_vector(1 downto 0);  -- data multiplexer selector

  signal pc_inc : std_logic;  -- program counter increment
  signal pc_dec : std_logic;  -- program counter decrement

  signal ptr_inc : std_logic; -- pointer increment
  signal ptr_dec : std_logic; -- pointer decrement
  signal ptr_reset : std_logic; -- pointer reset

  signal cnt_inc : std_logic; -- cnt incremet
  signal cnt_dec : std_logic; -- cnt decrement

  type fsm_state is (
    start_s,

    fetch_ptr_s,
    decode_ptr_s,

    ready_s,

    fetch_inst_s,
    decode_inst_s,

    inc_value_read_s,
    inc_value_write_s,

    dec_value_read_s,
    dec_value_write_s,

    print_read_value_s,
    print_value_to_lcd_s,

    input_read_value_s,
    input_save_value_s,

    inc_ptr_s,
    dec_ptr_s,

    while_start_s,
    while_start_cmp_val_s,
    while_start_while_s,
    while_proces_c_s,
    
    while_end_s,
    while_end_cmp_val_s,
    while_end_while_s,
    while_end_proces_c_s,
    while_proces_cnt_s,


    break_s,
    break_next_s,
    break_next_cmp_s,

    done_s,
    null_s
  );
  signal stateCur : fsm_state;
  signal stateNext : fsm_state;
begin

  -- Program counter register
  pc_cnt: process(CLK, RESET)
  begin
    if RESET = '1' then
      PC <= "0000000000000";
    elsif rising_edge(CLK) then
      if pc_inc = '1' then
        PC <= PC + 1;
      elsif pc_dec = '1' then
        PC <= PC - 1;
      end if;
    end if;
  end process;

  -- Pointer register

  ptr_cnt: process(CLK, RESET)
  begin
    if RESET = '1' then
      PTR <= "0000000000000";
    elsif rising_edge(CLK) then
      if ptr_inc = '1' then
        PTR <= PTR + 1;
      elsif ptr_dec = '1' then
        PTR <= PTR - 1;
      elsif ptr_reset = '1' then
        PTR <= (others => '0');
      end if;
    end if;
  end process;

  cnt_cnt: process(CLK, RESET)
  begin
    if RESET = '1' then
      CNT <= "00000000";
    elsif rising_edge(CLK) then
      if cnt_inc = '1' then
        CNT <= CNT + 1;
      elsif cnt_dec = '1' then
        CNT <= CNT - 1;
      end if;    
    end if;
  end process;
  -- MX1 address multiplexer selector

  DATA_ADDR <= PC when mx1_sel = '0' else PTR;  -- MX1 address multiplexer, 0 = PC, 1 = PTR

  -- MX2 data multiplexer 

  DATA_WDATA <= DATA_RDATA + 1 when mx2_sel = "00" else  -- MX2 data multiplexer, 00 = DATA_RDATA - 1, 01 = DATA_RDATA + 1, 10 = IN_DATA
                DATA_RDATA - 1 when mx2_sel = "01" else
                IN_DATA when mx2_sel = "10";
  
  
  state_cur: process (RESET, CLK, EN)
  begin
    if RESET = '1' then
      stateCur <= start_s;
    elsif (rising_edge(CLK)) then 
      if EN = '1' then
        stateCur <= stateNext;
      end if;
    end if;   
  end process;
  
  state_next: process (stateCur, IN_VLD, OUT_BUSY, DATA_RDATA)
  begin
    stateNext <= start_s;

    pc_inc <= '0';
    pc_dec <= '0';

    ptr_inc <= '0';
    ptr_dec <= '0';
    ptr_reset <= '0';

    cnt_inc <= '0';
    cnt_dec <= '0';

    mx1_sel <= '0';
    mx2_sel <= "00";

    OUT_WE <= '0';
    IN_REQ <= '0';
    DATA_EN <= '0';
    DATA_RDWR <= '0';

    OUT_DATA <= DATA_RDATA;

    case stateCur is

      when start_s =>
        READY <= '0';
        DONE <= '0';
        stateNext <= fetch_ptr_s;

      when fetch_ptr_s =>
        DATA_EN <= '1';
        DATA_RDWR <= '0';
        mx1_sel <= '1';
        stateNext <= decode_ptr_s;

      when decode_ptr_s =>
        if DATA_RDATA = X"40" then
          stateNext <= ready_s;
        else
          stateNext <= fetch_ptr_s;
        end if;
        ptr_inc <= '1';

      when ready_s =>
        READY <= '1';
        stateNext <= fetch_inst_s;
      
      when fetch_inst_s =>
        DATA_EN <= '1';
        DATA_RDWR <= '0';
        mx1_sel <= '0';
        stateNext <= decode_inst_s;

      when decode_inst_s => 
        case DATA_RDATA is
          when X"40" => stateNext <= done_s;
          when X"2B" => stateNext <= inc_value_read_s;
          when X"2D" => stateNext <= dec_value_read_s;
          when X"3E" => stateNext <= inc_ptr_s;
          when X"3C" => stateNext <= dec_ptr_s;
          when X"2E" => stateNext <= print_read_value_s;
          when X"2C" => stateNext <= input_read_value_s;
          when X"5B" => stateNext <= while_start_s;
          when X"5D" => stateNext <= while_end_s;
          when X"7E" => stateNext <= break_s;
          when others => stateNext <= null_s;
        end case;
      
      -------------------- INC MEMORY VALUE -------------------
      when inc_value_read_s =>
        -- Read value and set MX
	      mx1_sel <= '1';
        DATA_EN <= '1';
        DATA_RDWR <= '0';
        stateNext <= inc_value_write_s;

      when inc_value_write_s =>
        mx1_sel <= '1';
        mx2_sel <= "00";
        DATA_EN <= '1';
        DATA_RDWR <= '1';
        pc_inc <= '1';
        stateNext <= fetch_inst_s;
      
      ----------------------------------------------------------    
      
      --------------------- DEC MEMORY VALUE -------------------
      when dec_value_read_s =>
        -- Read value and set MX
        mx1_sel <= '1';
        DATA_EN <= '1';
        DATA_RDWR <= '0';
        stateNext <= dec_value_write_s;

      when dec_value_write_s =>
        mx1_sel <= '1';
        mx2_sel <= "01";
        DATA_EN <= '1';
        DATA_RDWR <= '1';
        pc_inc <= '1';
        stateNext <= fetch_inst_s;
      ----------------------------------------------------------  
      
      --------------------- INC PTR ----------------------------
      when inc_ptr_s =>
        ptr_inc <= '1';
        pc_inc <= '1';
        stateNext <= fetch_inst_s;
      ----------------------------------------------------------
      
      --------------------- DEC PTR ----------------------------
      when dec_ptr_s =>
        ptr_dec <= '1';
        pc_inc <= '1';
        stateNext <= fetch_inst_s;
      ----------------------------------------------------------
      
      ------------------- PRINT MEMORY VALUE -------------------
      when print_read_value_s =>
        DATA_EN <= '1';
        IN_REQ <= '1';
        DATA_RDWR <= '0';
        mx1_sel <= '1';
        stateNext <= print_value_to_lcd_s;

      when print_value_to_lcd_s =>
        mx1_sel <= '1';
        if OUT_BUSY = '0' then
          OUT_WE <= '1';
          OUT_DATA <= DATA_RDATA;
          pc_inc <= '1';
          stateNext <= fetch_inst_s;
        else
          stateNext <= print_read_value_s; ----check
        end if;
      ----------------------------------------------------------

      ------------------- READ VALUE TO MEMORY -----------------
      when input_read_value_s => 
          DATA_EN <= '1';
          IN_REQ <= '1';
          DATA_RDWR <= '0';
          mx1_sel <= '1';
          stateNext <= input_save_value_s;

      when input_save_value_s =>
        if IN_VLD = '1' then
          mx1_sel <= '1';
          mx2_sel <= "10";
          DATA_EN <= '1';
          DATA_RDWR <= '1';
          pc_inc <= '1';
          stateNext <= fetch_inst_s;
        else
          stateNext <= input_read_value_s;
        end if;
      ----------------------------------------------------------
      
      ------------------- WHILE START --------------------------
      when while_start_s =>
        pc_inc <= '1';
        -- read value
        DATA_EN <= '1';
        mx1_sel <= '1';
        DATA_RDWR <= '0';
        stateNext <= while_start_cmp_val_s;

      when while_start_cmp_val_s =>
        if DATA_RDATA = "00000000" then
          cnt_inc <= '1';
          stateNext <= while_start_while_s;
        else
          stateNext <= fetch_inst_s;
        end if;

      when while_start_while_s =>
        if CNT = "00000000" then
          stateNext <= fetch_inst_s;
        else
          --read command
          DATA_EN <= '1';
          DATA_RDWR <= '0';
          mx1_sel <= '0';
          stateNext <= while_proces_c_s;
        end if;

      when while_proces_c_s =>
        if DATA_RDATA = X"5B" then
          cnt_inc <= '1';
        elsif DATA_RDATA = X"5D" then
          cnt_dec <= '1';
        end if;
        pc_inc <= '1';
        -- go to while state
        stateNext <= while_start_while_s;
      ----------------------------------------------------------

      ------------------- WHILE END ----------------------------
      when while_end_s =>
        DATA_EN <= '1';
        DATA_RDWR <= '0';
        mx1_sel <= '1';
        stateNext <= while_end_cmp_val_s;

      when while_end_cmp_val_s =>
        if DATA_RDATA = "00000000" then
          pc_inc <= '1';
          stateNext <= fetch_inst_s;
        else
          cnt_inc <= '1';
          pc_dec <= '1';
          stateNext <= while_end_while_s;
        end if;

      when while_end_while_s =>
        if CNT = "00000000" then
          stateNext <= fetch_inst_s;
        else
          --read command
          DATA_EN <= '1';
          DATA_RDWR <= '0';
          mx1_sel <= '0';
          stateNext <= while_end_proces_c_s;
        end if;

      when while_end_proces_c_s =>
        if DATA_RDATA = X"5B" then
          cnt_dec <= '1';
        elsif DATA_RDATA = X"5D" then
          cnt_inc <= '1';
        end if;
        -- go to while state
        stateNext <= while_proces_cnt_s;

      when while_proces_cnt_s =>
        if CNT = "00000000" then
          pc_inc <= '1';
        else
          pc_dec <= '1';
        end if;
        stateNext <= while_end_while_s; -- check

      when break_s =>
        cnt_dec <= '1';
        pc_inc <= '1';
        stateNext <= break_next_s;

      when break_next_s =>
        -- read instruction until X"5D"
        DATA_EN <= '1';
        DATA_RDWR <= '0';
        mx1_sel <= '0';
        stateNext <= break_next_cmp_s;

      when break_next_cmp_s =>
        if DATA_RDATA = X"5D" then
          pc_inc <= '1';
          stateNext <= fetch_inst_s;
        else
          pc_inc <= '1';
          stateNext <= break_next_s;
        end if;


      when done_s =>
        DONE <= '1';
        stateNext <= done_s;
      
      when null_s =>
        pc_inc <= '1';
        stateNext <= fetch_inst_s;

      when others => 
        pc_inc <= '1';
        stateNext <= fetch_inst_s;

    end case;
  end process;  
  

 -- pri tvorbe kodu reflektujte rady ze cviceni INP, zejmena mejte na pameti, ze 
 --   - nelze z vice procesu ovladat stejny signal,
 --   - je vhodne mit jeden proces pro popis jedne hardwarove komponenty, protoze pak
 --      - u synchronnich komponent obsahuje sensitivity list pouze CLK a RESET a 
 --      - u kombinacnich komponent obsahuje sensitivity list vsechny ctene signaly. 

end behavioral;


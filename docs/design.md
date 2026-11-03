# QEMU machine model of the BRV32P SoC: design note (step Q0)

Source design: `RISCV_RV32IMC_5stage` (the BRV32P core and SoC), read-only. File and line references below are
to that repo at the revision this note was written against (`c9c2c9f`); `rtl/` paths are relative to it.

The aim is a QEMU machine, `-M brv32p`, that models the SoC closely enough for the same binaries to run on it
as on the RTL. There is no Linux and no MMU. Spike remains the ISA reference and the RTL the timing
reference. The custom extensions (Xbrvdsp, GF(2^8), mod-q) are step Q2 and are not covered here.

## 1. Memory map

The decode is partial, and it is the interconnect that does it (`rtl/bus/axi_interconnect.v:78-84`):

```
addr_is_periph(a) = (a[31:28] == 4'h2)
```

Any address with bits [31:28] = 2 goes to the peripheral bridge (slave 1). **Every other address goes to the
SRAM (slave 0)**, which ignores the upper address bits.

### SRAM

| Item | Value | Where |
|---|---|---|
| Size | 8192 words = 32 KB | `MEM_DEPTH = 8192`, `rtl/brv32p_soc.v:6`; `axi_sram` depth `rtl/bus/axi_sram.v:7` |
| Index | `addr[14:2]` (`AW = $clog2(DEPTH) = 13`) | `rtl/bus/axi_sram.v:32,108,112` |
| Aliasing | every non-peripheral address wraps modulo 32 KB, so 0x0000_0000, 0x1000_0000 and 0x8000_0000 are the same bytes | follows from the index; README "Memory Map" |
| Byte writes | per byte lane through `wstrb` | `rtl/bus/axi_sram.v:110-112` |
| Initial contents | NOP (`0x0000_0013`) everywhere, then `$readmemh(INIT_FILE)` | `rtl/bus/axi_sram.v:38-43` |
| Instruction and data | one unified memory; instruction fetch and data access go through separate caches to the same slave | `rtl/brv32p_soc.v:166-179` |

The firmware is loaded at word 0 (`INIT_FILE = "firmware.hex"`, `rtl/brv32p_soc.v:7`) and the core resets to
`RESET_PC = 0` (`rtl/brv32p_soc.v:8`). The ISA testbench instead sets `RESET_PC = 0x8000_0000` and loads the
image at word 0, so a test linked at 0x8000_0000 (like Spike's RAM) runs through the alias
(`tests/isa/tb_isa.v:35-46`, `tests/isa/env/link.ld`).

### Peripheral window

The bridge selects a device from `addr[11:8]` (`rtl/bus/axi_periph_bridge.v:26-36`); each device then decodes
a few more low bits of its own.

| `addr[11:8]` | Device | Base | Device decode |
|---|---|---|---|
| 0 | GPIO | `0x2000_0000` | `addr[4:2]` (`rtl/periph/gpio.v:64,79`) |
| 1 | UART | `0x2000_0100` | `addr[3:2]` (`rtl/periph/uart.v:68,126,186,199`) |
| 2 | Timer | `0x2000_0200` | `addr[4:2]` (`rtl/periph/timer.v:58,74`) |
| 3 to 15 | the GPIO again | `0x2000_0300` to `0x2000_0FFF` | `default: psel = 2'd0` (`axi_periph_bridge.v:33`) |

`addr[27:12]` is not decoded, so the whole 4 KB window repeats through the 256 MB at `0x2xxx_xxxx`. Registers
also repeat inside each device's window (the GPIO and timer every 32 bytes, the UART every 16).

The README lists the three 256-byte windows only; the repeats are what the RTL does.

### Access width on the peripheral bus

The bridge passes the peripheral the **whole 32-bit write data and ignores `wstrb`**
(`axi_periph_bridge.v:81`, `gpio_wdata=wdr`). The D-cache builds that word by repeating the stored value:
`SB` gives `{4{byte}}`, `SH` gives `{2{half}}` (`rtl/cache/dcache.v:109-116`). So `sb x, 0(gpio)` writes
`0xXXXXXXXX` to `data_out`, not just the low byte. Loads read the whole register and take the lane
(`dcache.v:67-95`). The model reproduces both.

## 2. Registers

All registers are 32 bits wide at word-aligned offsets. "RTL" gives the line that defines the behaviour.

### GPIO (`rtl/periph/gpio.v`)

| Offset | Name | Access | Reset | Behaviour |
|---|---|---|---|---|
| 0x00 | `DATA_OUT` | RW | 0 | output latch, `gpio.v:65,80` |
| 0x04 | `DATA_IN` | R | 0 | the pins after a two-flip-flop synchroniser (`gpio.v:32-40,81`); a write is ignored |
| 0x08 | `DIR` | RW | 0 | 1 = output, `gpio.v:66,82` |
| 0x0C | `IRQ_EN` | RW | 0 | per-pin enable, `gpio.v:67,83` |
| 0x10 | `IRQ_STAT` | R, W1C | 0 | a write clears the bits written as 1, `gpio.v:68,84` |
| 0x14 to 0x1C | | | | read as 0, writes ignored (`default`) |

* Pins driven out: `gpio_out = data_out & dir` (`gpio.v:91`).
* Interrupt status: on a rising edge of a synchronised input, `irq_stat |= rising_edge & irq_en`
  (`gpio.v:50-51,61`). The enable is applied when the edge happens, so an edge on a pin whose enable is clear is
  not remembered. `rising_edge` is `gpio_in_sync & ~gpio_in_prev` (a third flip-flop), so a pin change reaches
  `irq_stat` three clocks after it. A write-1-to-clear in the same cycle wins over the set (the `if (wr_en)`
  assignment is last).
* IRQ line: `irq = |(irq_stat & irq_en)` (`gpio.v:92`), a level.

### UART (`rtl/periph/uart.v`)

8N1, no parity, no FIFO.

| Offset | Name | Access | Reset | Behaviour |
|---|---|---|---|---|
| 0x00 | `TXDATA` | W (reads 0) | | A write takes effect **only if the transmitter is idle** (`tx_state == TX_IDLE`, `uart.v:66-73`); a write while a frame is going out is dropped. It loads `tx_shift` from `wdata[7:0]`, sets `tx_busy` and starts the frame. |
| 0x04 | `RXDATA` | R | 0 | the last received byte (`uart.v:188`). **A read clears `rx_valid`** (`uart.v:126-127`), whatever the byte. A write is ignored. |
| 0x08 | `STATUS` | R | 0 | `{29'b0, rx_overrun, rx_valid, tx_busy}` (`uart.v:189`): bit 0 `tx_busy`, bit 1 `rx_valid`, bit 2 `rx_overrun`. A write is ignored. |
| 0x0C | `CLKDIV` | RW (16 bits) | **867** | `clk_div <= wdata[15:0]` (`uart.v:196-202`); reads back the 16 bits (`uart.v:190`). |

* Timing. Each bit lasts `clk_div + 1` clocks. A frame is a start bit, 8 data bits (LSB first), a stop bit:
  `TX_START`, `TX_DATA`, `TX_STOP` each count `tx_clk_cnt` from `clk_div` down to 0 (`uart.v:76-111`).
  `tx_busy` is set by the write and cleared at the end of the stop bit, so it is high for
  `1 + 10 * (clk_div + 1)` clocks after the write edge. The reset value 867 is 115,200 baud at 100 MHz.
* Receive. The receiver waits for the falling edge of the synchronised `uart_rx`, samples the middle of the
  start bit (`clk_div/2`), then each data bit at `clk_div + 1` intervals, and at the middle of the stop bit
  (`uart.v:130-177`). The byte is kept only if the stop bit is 1. If `rx_valid` is still set when a new byte is
  complete, `rx_overrun` is set and the new byte replaces the old (`uart.v:168-172`). **`rx_overrun` is sticky:
  nothing but reset clears it.**
* IRQ: `irq = rx_valid` (`uart.v:204`), a level; it drops when `RXDATA` is read. There is **no TX interrupt and
  no enable bit**: the UART interrupt is always enabled at the source and is masked only by `mie.MEIE`.

### Timer (`rtl/periph/timer.v`)

| Offset | Name | Access | Reset | Behaviour |
|---|---|---|---|---|
| 0x00 | `CTRL` | RW | 0 | bit 0 `enable`, bit 1 `auto_reload`; `{auto_reload, enable} <= wdata[1:0]` (`timer.v:59,75`). Other bits read 0. |
| 0x04 | `PRESCALER` | RW | 0 | a tick every `prescaler + 1` cycles (`timer.v:60`) |
| 0x08 | `COMPARE` | RW | 0xFFFF_FFFF | `timer.v:36,61` |
| 0x0C | `COUNT` | RW | 0 | `timer.v:62,78` |
| 0x10 | `STATUS` | R, W1C | 0 | bit 0 `match_flag`; `match_flag & ~wdata[0]` on a write (`timer.v:63,79`) |

* Prescaler. While enabled, `pre_cnt` counts 0, 1, ... up to `prescaler` and a tick is the cycle in which
  `pre_cnt == prescaler` (`timer.v:29,41-46`). `pre_cnt` is not reset by a write to `CTRL`, so enabling a
  stopped timer continues from where `pre_cnt` stopped. If `prescaler` is lowered below `pre_cnt`, `pre_cnt`
  returns to 0 without a tick (`>=`, `timer.v:42`).
* Counter. On a tick, `if (count >= compare) { match_flag = 1; if (auto_reload) count = 0; } else count++`
  (`timer.v:48-55`). So with `count = 0` and `compare = N` the flag is set on tick number N + 1. Without
  auto-reload the count stays at `compare`, and the flag, once cleared, is set again at the next tick.
* A write to `COUNT` or `STATUS` in the same cycle as a tick wins over the tick.
* IRQ: `irq = match_flag` (`timer.v:85`), a level, cleared only by writing 1 to `STATUS`. There is no enable
  bit: the interrupt is masked only by `mie.MTIE`.

## 3. Interrupts and the CSR unit

There is no PLIC and no CLINT. The wiring is in `rtl/brv32p_soc.v:80-81`:

```
.ext_irq   (gpio_irq | uart_irq),
.timer_irq (timer_irq),
```

and the CSR unit forms `mip` from them (`rtl/core/csr.v:44-49`): `mip[11] = ext_irq` (MEIP) and
`mip[7] = timer_irq` (MTIP). Both are read-only levels; no other `mip` bit exists, and there is no software
interrupt (MSIP). So, as the task description says, the external interrupt is the OR of the GPIO and UART
interrupts, and the timer is MTIP. Checked against the RTL: it is.

| Item | RTL | Where |
|---|---|---|
| Taken when | `mstatus.MIE && \|(mip & mie)` | `csr.v:50` |
| Priority | external (code 11) before timer (code 7) | `csr.v:51-52` |
| `mcause` | `0x8000_000B` (external), `0x8000_0007` (timer) | `rtl/core/brv32p_core.v:673-674` |
| Entry | `pc = mtvec`, **direct mode only**: `mtvec <= {nv[31:2], 2'b00}` | `brv32p_core.v:173-174`, `csr.v:114` |
| `mepc` | the address of the interrupted instruction (the one in EX); `{nv[31:1], 1'b0}` on a write | `brv32p_core.v:649-659,759`, `csr.v:116` |
| `mstatus` | only MIE (bit 3) and MPIE (bit 7) exist: `nv & 0x88`. Entry: `MPIE = MIE; MIE = 0`. `MRET`: `MIE = MPIE; MPIE = 1`. There is no MPP. | `csr.v:101-109,112` |
| Exceptions | illegal instruction (2), breakpoint (3), load address misaligned (4), store address misaligned (6), ECALL from M-mode (11); `mtval` is the address for 4 and 6, 0 otherwise | `brv32p_core.v:660-677` |
| CSRs present | `mstatus` 300, `mie` 304, `mtvec` 305, `mscratch` 340, `mepc` 341, `mcause` 342, `mtval` 343, `mip` 344, `mcycle` B00, `minstret` B02, `mhartid` F14 (reads 0) | `csr.v:55-71`, `rtl/pkg/brv32p_defs.vh:103-113` |
| Unknown CSR | reads 0, a write is ignored; **no trap** | `csr.v:69,119` |
| `WFI` | decodes as illegal (SYSTEM funct12 other than 000, 001, 302) and traps | `rtl/core/decoder.v:170-177` |
| Misaligned load or store | traps (the access is suppressed); instruction fetch at 2-byte alignment is fine (C extension) | `brv32p_core.v:505-510` |
| `FENCE.I` | invalidates the I-cache and refetches | `brv32p_core.v:512-519` |

Not in the RTL (relative to a generic RISC-V machine): `misa`, `mvendorid`, `marchid`, `mimpid`, `mcountinhibit`,
`mcounteren`, `cycle`/`time`/`instret` (user counters), `mcycleh`/`minstreth`, PMP, user and supervisor mode,
vectored `mtvec`, `MPP`.

## 4. Reset and boot flow

* Reset PC: `RESET_PC`, parameter default **0x0000_0000** (`rtl/brv32p_soc.v:8`, `brv32p_core.v:6,109`).
  The ISA testbench overrides it to 0x8000_0000 (`tests/isa/tb_isa.v:38`).
* There is no boot ROM and no bootloader. The SRAM is initialised from `firmware.hex` before reset
  (`axi_sram.v:38-43`); the first instruction executed is the first word of that image.
* All CSRs reset to 0 (`csr.v:86-95`): interrupts are off (`mstatus.MIE = 0`) and `mtvec = 0`, so a trap with
  no handler set restarts the program at address 0. The SoC firmware relies on that: its final `ECALL`
  restarts it (`firmware/gen_firmware.py:138-141`).
* The firmware (`firmware/gen_firmware.py`, 59 instructions) does ALU, load/store, branch and jump checks,
  writes `0x34` (52) to the GPIO output with `DIR = 0xFF`, sets the UART divider to 8, sends `'H'`, reads
  `mcycle`, and ends with `ECALL`. Its observable results are the GPIO pattern, the UART byte and a final trap
  with `mcause = 11`, `mepc = 0xB4`.

## 5. How tests end

The riscv-tests report their result through `tohost`:

| `tohost` value | Meaning |
|---|---|
| 1 | pass |
| `(testnum << 1) \| 1` | fail in test case `testnum` |
| `(1337 << 1) \| 1` | any trap taken (the core's env, `tests/isa/env/riscv_test.h`) |

On the RTL `tohost` is **plain SRAM**: the test stores a word, and the testbench watches the core's retire trace
for a store to the address of the `tohost` symbol (`tests/isa/tb_isa.v:158-166`; the address comes from `nm`,
`tests/isa/run_isa.sh:96`). The env stores only the **lower** 32-bit word; `tohost` is a `.dword` and the upper
word is never written.

### The choice for QEMU

The proposal was to reuse QEMU's HTIF as `-M spike` does. Reading `hw/char/riscv_htif.c` (v11.1.3) shows that is
not enough as it stands:

* On RV32 the HTIF device acts on a `tohost` write only when the **upper** word is written
  (`htif_mm_write`, the `TOHOST_OFFSET2` branch calls `htif_handle_tohost_write`; the lower word is only kept).
  The upstream riscv-tests env writes both words, which is why Spike works; the core's env writes only the
  lower one, so the run would never end.
* HTIF also requires an 8-byte `fromhost` symbol and exits the whole program if there is none.

So the decision is: **keep HTIF's exit convention and symbol discovery, but act on the first 32-bit store to
`tohost`**. When the ELF given with `-kernel` has a `tohost` symbol, the machine puts a small 4-byte MMIO word
over that address (priority above the SRAM). A store with bit 0 set ends the run with exit status
`value >> 1`; a store with bit 0 clear is kept and does nothing. Loads read back what was stored, as the SRAM
would. Pass is exit status 0, a failing case N gives N, a trap gives 1337 mod 256 = 57 (the shell shows only
the low 8 bits).

This works for both envs, because the upstream env stores the lower word first, and needs no change to the
binaries. If there is no `tohost` symbol (the SoC firmware, which never exits), nothing is mapped.

Alternatives considered:

| Alternative | Why not |
|---|---|
| Use QEMU's HTIF unchanged | does not end on the core's env (lower-word-only store) and needs `fromhost` |
| Patch `riscv_htif.c` to act on the lower word | touches a file shared with `-M spike` for a convention only this machine needs |
| Semihosting (`-semihosting`, `SYS_EXIT`) | needs the binaries to execute the semihosting `slli/ebreak/srai` sequence: a change to the binaries |
| A write to a magic MMIO address, as a test-finisher device does | needs a change to the binaries, and the RTL has nothing at that address |
| A QMP/qtest poller reading `tohost` | works with no exit device but is slow, racy against the store, and needs a host helper for every run |
| Watch the store in the translator | invasive in the TCG core, and it would be hidden state in a generic CPU |

## 6. What Q1 models and what it leaves out

Modelled:

* one RV32IMC hart in machine mode with Zicsr, Zifencei and Zbkb, Zbkc, Zbkx, Zknd, Zkne, Zknh (the `-march`
  of the benches, `tests/bench/run_bench.sh:18-19`); a new CPU type `brv32p`;
* misaligned loads and stores trap, as the core does (an internal CPU option);
* the SRAM at 0x0000_0000 with an alias at 0x8000_0000 (the two addresses the RTL is used at);
* the GPIO, UART and timer register-exact, including single-word bus accesses, the repeats inside the
  windows, and the GPIO at `addr[11:8] = 3..15` of the first 4 KB;
* the interrupt wiring of section 3: no PLIC, MEIP = GPIO or UART, MTIP = timer;
* UART and timer timing in cycles at a nominal 100 MHz (`clock-frequency`), taken from QEMU's virtual clock;
  with `-icount shift=3` (8 ns per instruction) the run is deterministic;
* `-kernel` ELF loading, reset PC = the ELF entry (as `RESET_PC` is set for the ISA tests), and the `tohost`
  exit of section 5. Without `-kernel`, a raw image given with `-device loader,addr=0` runs from 0.

Left out, and where the model therefore differs from the RTL:

| Left out | Effect |
|---|---|
| **Cycle timing.** One instruction takes one unit of virtual time, not the CPI of the pipeline. | The time of interrupts relative to the program, and `mcycle`, are not those of the RTL. |
| **Caches.** | See below: this matters for peripheral reads. |
| **AXI** and the bridge handshakes. | No bus latency, no write-buffer ordering. |
| Aliases of the SRAM other than 0x0 and 0x8000_0000; the repeat of the peripheral window through `0x2xxx_xxxx`; SRAM beyond 32 KB (the RTL wraps, the model has an access fault). | A program that relies on wrap-around differs. |
| The 2- and 3-clock input delay of the GPIO. | A pin change is seen at once. |
| **Unknown CSRs, `WFI`.** | The RTL reads 0 and ignores writes for any CSR it does not have (no trap), and `WFI` traps. In the model a CSR that does not exist raises an illegal-instruction exception (`time`, the `0x7c0` custom range), the generic CSRs `cycle`, `instret`, `misa` and `mvendorid` read their own values (the RTL reads 0), and `WFI` runs. A binary that passes on the RTL does not use them. |
| `mstatus.MPP`, `misa`, `mtvec` vectored mode, the other machine CSRs of section 3. | QEMU's CSR unit is the generic RISC-V one: `mstatus` reads with `MPP = 3`, `misa` exists. |

### A finding in the RTL: peripheral registers go through the D-cache

`rtl/cache/dcache.v` has **no bypass for peripheral addresses**: every load and store, including those to
`0x2xxx_xxxx`, is looked up by tag and a read miss fills a 16-byte line with four word reads
(`dcache.v:52-66,158-162`). Two consequences, both seen in simulation:

* After the first access, a peripheral register read is served from the cache. A program that enables the
  timer and reads `COUNT` twice, 200 loop iterations apart, gets the same value both times (Icarus,
  `tb_isa.v`, FAIL). Polling `UART STATUS` or `GPIO DATA_IN` would spin on a stale word.
* A line fill reads the neighbouring registers, with their side effects: filling the UART line (0x100 to 0x10C)
  reads `RXDATA` (0x104), which clears `rx_valid`.

The model has no cache, so its peripheral reads are always live. The RTL as it stands cannot poll a peripheral.
This is not changed here (the core repo is read-only for this work); it is reported to the owner. A fix would
be to bypass the cache for `addr[31:28] == 2`.

## 7. Outline of Q2 and Q3

**Q2: the custom extensions.** Xbrvdsp, the GF(2^8) multiply and the mod-q unit are added to the `brv32p` CPU as
a QEMU vendor extension: a `xbrvdsp.decode` decodetree file (as `xthead.decode` and `xlrbr.decode` are done in
`target/riscv`), with helper functions where an instruction is not a few TCG ops (saturating add, the packed
halves, the address generators and the hardware-loop registers, the mod-q reduction). The encodings and
semantics are those of the RTL decoder and of the Spike model in the core repo
(`tools/spike_xbrvdsp`): that library is the reference, and each QEMU instruction is checked against it,
instruction by instruction, with the same directed tests (`tests/directed/dsp_*`, `gf`, `mq`, `mul_use`) and
randomised operands. The state the extension adds (AGU registers, loop registers) is added to `CPURISCVState`
and to the migration description.

**Q3: one ELF, three simulators.** A CI job builds a test ELF once, runs it on QEMU, on Spike (with the
extension library) and on the RTL (Icarus), and compares: the final `tohost` value, the UART output, and for
the instructions both sides can log, the commit log (QEMU's `-d` trace against Spike's `--log-commits`, as the
core repo's `lockstep.py` already compares Spike with the RTL). The three results must agree on pass/fail and
output; the cycle counts of course differ, and are reported only for the RTL.

## 8. Test plan for Q1

| Suite | What | Count |
|---|---|---|
| ISA | riscv-tests rv32ui, rv32um, rv32uc, rv32ui-c, rv32um-c as built for the core, and the directed tests without custom instructions (`csr_use`, `fence_i_fill`, `fence_i_warm`, `misaligned`, `timer_irq`, `zk`) | `tests/run_isa.sh` |
| rv32mi | the machine-mode tests, built with the upstream env; on the model and Spike only, as the core repo does not run them | `tests/run_isa.sh rv32mi` |
| Machine | SoC firmware (UART byte, GPIO pattern, registers, `mcause = 11`), `timer.S`, `uart.S`, `gpio.S` | `tests/run_machine.py` |

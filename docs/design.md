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
| **Caches.** | The RTL's D-cache now bypasses the peripheral window (see below), so peripheral reads agree; the model's cacheless reads are live. |
| **AXI** and the bridge handshakes. | No bus latency, no write-buffer ordering. |
| Aliases of the SRAM other than 0x0 and 0x8000_0000; the repeat of the peripheral window through `0x2xxx_xxxx`; SRAM beyond 32 KB (the RTL wraps, the model has an access fault). | A program that relies on wrap-around differs. |
| The 2- and 3-clock input delay of the GPIO. | A pin change is seen at once. |
| **Unknown CSRs, `WFI`.** | The RTL reads 0 and ignores writes for any CSR it does not have (no trap), and `WFI` traps. In the model a CSR that does not exist raises an illegal-instruction exception (`time`, the `0x7c0` custom range), the generic CSRs `cycle`, `instret`, `misa` and `mvendorid` read their own values (the RTL reads 0), and `WFI` runs. A binary that passes on the RTL does not use them. |
| `mstatus.MPP`, `misa`, `mtvec` vectored mode, the other machine CSRs of section 3. | QEMU's CSR unit is the generic RISC-V one: `mstatus` reads with `MPP = 3`, `misa` exists. |

### A finding in the RTL: peripheral registers went through the D-cache (fixed in core PR #30)

**Fixed in core PR #30 (`bc75bf8`):** the D-cache bypasses `addr[31:28] == 2`, and a finished uncached access
is not repeated under a fetch stall. The model never had the problem (it has no cache); it is kept here as
history. What Q0 found at `c9c2c9f`: `rtl/cache/dcache.v` had no bypass for peripheral addresses, so every
load and store to `0x2xxx_xxxx` was looked up by tag and a read miss filled a 16-byte line with four word
reads. A program that read the timer's `COUNT` twice, 200 loop iterations apart, got the same value both
times, and filling the UART's line read `RXDATA` (0x104), which cleared `rx_valid`. With the fix, peripheral
registers can be polled on the RTL as they are on the model.

## 7. Outline of Q2 and Q3

**Q2: the custom extensions.** Done: section 9 (the design) and section 10 (the tests).

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

## 9. Q2: the custom extensions

Xbrvdsp (the multiply-accumulate unit, the address registers and the hardware loop), the packed GF(2^8)
multiply and the mod-q unit are a vendor extension of the `brv32p` CPU, patch 0007. It is on for `brv32p` only
(the cfg flag `ext_xbrvdsp`, set in the CPU's definition), and is in the ISA string as `xbrvdsp`. The reference
is the core repo's Spike model, `tools/spike_xbrvdsp/xbrvdsp.cc`, loaded as `libxbrvdsp.so`: every QEMU
instruction is checked against it, instruction by instruction (section 10). The RTL (`decoder.v`,
`dsp_unit.v`, `agu.v`, `loop_unit.v`, `gf_unit.v`, `mq_unit.v`) was read alongside it.

### Decode

`target/riscv/xbrvdsp.decode` is a decodetree file in the vendor-extension pattern: its decoder is added to
`decoder_table` in `translate.c`, gated on `ext_xbrvdsp`. The 45 patterns fix every field the RTL decoder
requires to be zero (`rd` for the accumulator updates, `rs1` and `rs2` for the reads, the upper bits of `rd`
for the address-register writes, the upper bits of the immediate for the loads and reads), so the same words
are illegal in the model and in the RTL, and in Spike (whose masks are the same). A word the patterns do not
match raises an illegal-instruction exception.

| Group | Opcode, funct3 | Instructions |
|---|---|---|
| accumulator | custom-0 (0x0B), 000, 001, 010, 011 | `mac` `dmac` `msu` and their `.lp` forms (funct7 bit 6), `acc.set` `acc.seth` `acc.rd` `acc.rdh` `acc.rdl` `acc.rdx` |
| saturating, packed | custom-0, 100 | `sadd` `ssub` `radd16` `rsub16` `pk16` |
| GF(2^8) | custom-0, 101 | `gfmul4` `gf.cfg` `gf.rd` |
| mod q | custom-0, 110 | `mqmul2` `mqadd2` `mqsub2` `ctadd2` `ctsub2` `gsmul2` `mq.cfg` `mq.zeta` `mq.rd` `mq.rdz` |
| address registers | custom-1 (0x2B), 000, 001, 010, 011, 101 | `ar.set` `ar.cfg` `ar.mode` `ar.rd` `ar.rds` `ar.rdm` `lh.a` `lw.a` `lhu.a` |
| hardware loop | custom-1, 000, 011, 110, 111 | `lp.setup` `lp.set` `lp.sets` `lp.rd` `lp.rds` `lp.end` |

### State

In `CPURISCVState` (`cpu.h`), reset in `riscv_cpu_reset_hold` to the RTL's reset values, and migrated in the
`cpu/xbrvdsp` subsection (`machine.c`), present only when the extension is on:

| State | Size | Reset | RTL |
|---|---|---|---|
| accumulator | 40 bits, held sign-extended in 64 | 0 | `dsp_unit.v` |
| `ar0` to `ar3`: address, stride, bit-reversed mode | 32, 16, 1 bits each | 0, 0, 0 | `agu.v` |
| loop count `lc`, loop start `lp_start` | 32 bits each | 0, 0 | `loop_unit.v` |
| GF polynomial | 8 bits | 0x1D | `gf_unit.v` |
| `q`, `q'`, `zeta` | 16 bits each | 3329, 3327, 0 | `mq_unit.v` |

The RTL's `zqp` register (zeta times q' mod 2^16) is a timing device of its two-stage multiplier; its effect
is the same product, so the model does not keep it.

### The arithmetic

Helpers (`target/riscv/tcg/xbrvdsp_helper.c`) do everything that is not a move of a register: the accumulate
and the rounded, saturating reads, the saturating and packed-half operations, the byte-lane GF multiply by
Horner's rule, the Montgomery multiply and reduction mod q, the stepping of an address register (including
the reverse-carry add of the bit-reversed mode) and the loop count. The translator (`trans_xbrvdsp.c.inc`)
picks the helper and moves the registers. The helper code is a transcription of the Spike model; where the
RTL computes the same function by a different route (the GF fold of x^(8+j), the 17-bit mod-q reductions) the
two agree for every operand, which the randomised tests exercise.

### Address registers: the load comes first

`lh.a`, `lw.a` and `lhu.a` read the address register, do the load with the alignment check on, and only then
call the helper that steps the register. A misaligned load raises the load-address-misaligned exception
(`mtval` is the address) and leaves the register as it was, as `agu.v` and Spike do.

### The hardware loop

The loop-back is a branch whose target is only known at run time, so `mac.lp`, `dmac.lp`, `msu.lp` and `lp.end`
end the translation block: the multiply-accumulate (if any) runs, then a helper takes the next pc: while
`lc > 1` it counts down and returns `lp_start`, otherwise `lc` becomes 0 and it returns the address of the next
instruction. `lp.setup` sets `lc = rs1` and `lp_start = pc + 4`; a count of 0 or 1 runs the body once.

Interrupts and traps are taken between instructions, and a loop-ending instruction either completes (counts
down, goes round) or has not started; QEMU never leaves it half done, as the RTL's EX-stage squash never lets
a squashed one update `acc` or `lc`. So, as `dsp_irq.S` tests:

* An interrupt taken when the next instruction is a loop-ending one has `mepc` = the address of that
  instruction. After `mret` it runs once, and counts down once. The interrupt neither adds nor counts.
* An interrupt taken after a loop-back has `mepc` = `lp_start` (the instruction the loop went back to).
* A loop-ending instruction cannot itself raise an exception (it only touches the accumulator and the loop
  registers), so there is no `mepc` of a trap from one other than the above. A trap inside a body (a
  misaligned `lw.a`, say) has `mepc` = that load; the loop registers are not saved by the trap, so a handler
  that uses a hardware loop must save and restore them (`lp.rd`, `lp.rds`, `lp.set`, `lp.sets`).
* `lc` and `lp_start` are one set, not a stack: the loops do not nest.

Not covered, because neither Spike nor the tests do: a `lp_start` with bit 0 set (an odd address) and a
loop body that runs into the interrupt of a peripheral that is not modelled.

### Differences found

Reading the RTL against the Spike model (decode masks, reset values, rounding and saturation, the
bit-reversed step, the loop count, the mod-q reductions, `lp.rd` and `lp.rds`) found none: the two agree, and the
core repo's own lockstep (RTL against Spike) agrees with that. The differences between the model and the RTL
are timing only (a QEMU instruction is one unit of time; the RTL's `mqmul2` takes two cycles in MEM) and are not observable to a program, other than through `mcycle`.


## 10. Test plan for Q2

| Suite | What | Where |
|---|---|---|
| ISA | the 7 directed tests that use the custom instructions (`dsp_agu`, `dsp_irq`, `dsp_loop`, `dsp_mac`, `gf`, `mq`, `mul_use`), now run with the rest of the directed tests | `tests/run_isa.sh` |
| Lockstep | the six of them Spike can run (all but `dsp_irq`, which needs the timer and checks itself) and five randomised operand tests, QEMU against Spike | `tests/run_lockstep.sh` |

The lockstep builds each test as the core repo's runner does and runs it on QEMU with the `execlog` TCG plugin
(`-d plugin,int`, the 31 general registers watched) and on Spike (`--extlib=libxbrvdsp.so --extension=xbrvdsp
--log-commits`). `tests/lockstep_qemu.py` compares, per retired instruction, the pc, the encoding and the
register written, so every result of every custom instruction (they all end up in a register), including the
state reads `acc.rd*`, `ar.rd*`, `lp.rd*`, `gf.rd` and `mq.rd*`. The plugin logs a register only when its value
changes and logs an instruction that traps; the script keeps a register shadow, and drops the record of a
trapping instruction (named by the `-d int` line). A mismatch fails the test. The run must end at QEMU's store
to `tohost`, which must be Spike's matching store.

`tests/gen_random.py` writes the randomised tests (fixed seed): 256 operand sets per instruction, drawn at
random with a bias to the edges (0, -1, the 16- and 32-bit limits), the results stored to memory.

| File | Covers |
|---|---|
| `rand_alu` | `mac` `dmac` `msu` `acc.set` `acc.seth` `acc.rdl` `acc.rdx` over random 40-bit accumulators; `acc.rd` and `acc.rdh` at 12 shifts each; `sadd` `ssub` `radd16` `rsub16` `pk16`, also with `rd` = `rs1` or `rs2` |
| `rand_gf` | `gfmul4` for 12 polynomials (0x1D, 0x1B, 0x00, 0xFF, 0x01, 0x87 and six random), `gf.cfg`, `gf.rd` |
| `rand_mq` | the six mod-q operations over 8 configurations of `q` and `q'` (the ML-KEM, 12289 and 7681 pairs, a `q'` that is not -q^-1, `q` = 0, 1 and 65535) with a new random `zeta` for every operand set; `mq.cfg`, `mq.zeta`, `mq.rd`, `mq.rdz` |
| `rand_agu` | `ar.set` `ar.cfg` `ar.mode` `ar.rd` `ar.rds` `ar.rdm` `lh.a` `lw.a` `lhu.a` over random address register, start, stride and load kind, plain (56 chains) and bit-reversed (32 chains) |
| `rand_loop` | 120 loops of random count (0 to 60) and shape (`mac.lp`, `dmac.lp`, `msu.lp` and `lp.end` as last instruction; a load, a branch or a GF multiply in the body; set up by `lp.setup` or `lp.set` and `lp.sets`), reading `lc` and `lp_start` with `lp.rd` and `lp.rds` |

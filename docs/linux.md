# Linux on BRV32P, stage 1: the decision record

Stage 1 settles what the software side of Linux needs from the SoC, before any RTL changes. It adds a second
machine to the model, `-M brv32p-linux`, and boots OpenSBI and Linux to a BusyBox shell on it. `-M brv32p` and its
tests are unchanged. Everything in the machine that the RTL does not have today is listed in section 5, which is
the list the RTL stages (2 to 5) implement.

## 1. The machine: `-M brv32p-linux`

A separate machine type (patch 0008), not a `linux=on` property on `brv32p`. Reasons: the CPU differs (a new CPU
type, `brv32p-linux`), the memory map differs, and the boot path differs (firmware, kernel, DT). A property would
leave `brv32p` carrying code paths its tests never run, and the brief requires `-M brv32p` to stay exactly as it is.

| Item | `brv32p` | `brv32p-linux` |
|---|---|---|
| CPU | RV32IMC, M-mode, `misa` I M C | RV32IMAC, M, S and U modes, Sv32, Zicsr, Zifencei, Zicntr (`cycle`/`time`/`instret` and the high halves), no PMP |
| BRV32P custom extensions | on | on (Xbrvdsp, GF(2^8), mod-q, Zbk*, Zkn*), and misaligned loads and stores still trap |
| Boot SRAM | 32 KB at 0 and aliased at 0x8000_0000 | 32 KB at 0 (the RTL's reset address) only; holds the reset vector |
| RAM | none | 128 MiB at 0x8000_0000, fully decoded, no aliasing |
| GPIO, UART, timer | 0x2000_0000, 0x2000_0100, 0x2000_0200 | the same, register-exact |
| Timer and software interrupt | BRV32P timer on MTIP | the BRV32P timer is kept, and an ACLINT in the SiFive CLINT layout is added at 0x2001_0000: `msip` at +0, `mtimecmp` at +0x4000, `mtime` at +0xbff8, 10 MHz |
| Interrupt controller | none (GPIO or UART gives MEIP) | none; the same OR into MEIP |
| Power-off | `tohost` | a finisher at 0x2002_0000 (QEMU's `sifive_test`) used by the SBI reset; a test aid, not an RTL requirement |

The device tree is [`linux/brv32p-linux.dts`](../linux/brv32p-linux.dts), passed with `-dtb`. OpenSBI
(`fw_dynamic`) is loaded at 0x8000_0000 with `-bios`, the kernel after it, the initramfs after the kernel, and the
DT at the top of RAM, as for the virt machine. The reset vector is written into the boot SRAM at 0 (the RTL's
`RESET_PC`); in the RTL that SRAM is initialised from `firmware.hex`, so stage 2's first-stage image is exactly
this stub (set `a0` = hart id, `a1` = DT address, `a2` = `fw_dynamic` info, jump to 0x8000_0000).

## 2. Timer and interrupts: the minimum the RTL adds

| Option | Verdict |
|---|---|
| Keep only the BRV32P timer | Does not work: it is a 32-bit prescaled counter on MTIP with no `mtime`, so OpenSBI has no timer device and Linux has no clocksource |
| **CLINT or ACLINT (mtime, mtimecmp, msip)** | **Chosen.** OpenSBI and Linux support the layout as it stands. About 64 bits of `mtime`, 64 of `mtimecmp`, one `msip` bit, one bus slave. Linux sets timers through SBI `set_timer`, so no `stimecmp` (Sstc) is needed |
| PLIC for the UART | **Not needed in stage 1.** The console is polled through the SBI, and nothing else in the machine interrupts. Add the PLIC when a second interrupt source needs it (see section 4) |
| Keep GPIO or UART OR-ed into MEIP | Kept as is; OpenSBI does not use it |

`time` is a counter CSR in the model. The RTL has no `time` CSR. Either add `time` as a read of `mtime`, or leave
it out and let OpenSBI emulate `rdtime` on the illegal-instruction trap (it does); the first is cheaper in boot
time, the second is free in RTL.

## 3. Console: (a) SBI console, chosen

| | (a) OpenSBI driver for the existing UART | (b) ns16550-compatible UART in the SoC |
|---|---|---|
| RTL cost | none | a new register map (RBR/THR, IER, IIR/FCR, LCR, LSR and more), at least a TX-empty and RX-ready status in LSR, and the interrupt logic; the UART's TX-idle-only write and read-clears-valid behaviour would have to change |
| Software cost | a 40-line OpenSBI driver ([`linux/patches/opensbi`](../linux/patches/opensbi)) matching `brv32p,uart`; Linux uses `earlycon=sbi` and `hvc_riscv_sbi` | none, stock drivers |
| Behaviour | the console is polled; a character costs about 87 us of busy-wait at 115,200 baud inside OpenSBI | interrupt-driven if the PLIC exists |

(a) needs no RTL change and is what the machine uses. Its cost is that every console character is an `ecall` and a
busy-wait in M-mode. That is acceptable for a bring-up console; (b) is the choice if the UART becomes a data
path. The kernel needs `CONFIG_RISCV_SBI_V01` for the legacy console calls (see the kernel fragment).

## 4. Reuse of the owner's own IP

Each was assessed by re-running its tests in a scratch copy and reading its interface against the BRV32P bus.

| Repo | Tests re-run (scratch copy) | Interface against the BRV32P bus | Missing for Linux | Verdict |
|---|---|---|---|---|
| `MMU` (Sv32 MMU, TLB, walker, `SFENCE.VMA`) | SystemVerilog 80 / 80 pass; cocotb 51 / 51 pass (run module by module: `scripts/run_cocotb.sh all` prints FAILED after the first module because it greps "FAIL" and matches the summary "FAIL=0", a script bug and not an RTL failure) | one request at a time, valid/ready, with `vaddr`, load/store/exec, one `priv_mode` bit, `satp`, `mxr`, `sum`, `sfence_*`; returns `paddr`, `page_fault`, a 2-bit fault type (causes 12, 13, 15). The walker has its own valid/ready 32-bit read port. Not AXI | I and D ports (the core has two cache masters), `MPRV`, a proper privilege input, hardware A/D update (absent: A=0 or a store with D=0 faults, which Linux handles, at the cost of extra traps), a flush of VA 0 or ASID 0 specifically (0 is the wildcard in `tlb.sv`); several cycles per hit; no MMU-to-core wiring exists | **adapt**, small to medium |
| `RISCV_PLIC` | SystemVerilog 7 testbenches, 81 `[PASS]`, 0 `[FAIL]`; cocotb 41 / 41 pass. The README says 65 SV tests; the re-run shows 81, so the README headline is stale (its own table adds up to 81) | the register map is the standard one (priority 0x0, pending 0x1000, enable 0x2000 + 0x80 per context, threshold and claim 0x200000 + 0x1000 per context). Bus is a single-cycle valid/ready with a 26-bit address, not AXI: a thin bridge, like `axi_periph_bridge`, is needed. Level-triggered gateways; one `eip` per context (two contexts per hart for M and S) | nothing for the stage-1 machine, which has no PLIC | **reuse as is behind a bridge** (about 1 to 2 days), when a second interrupt source needs it |
| `RISCV_SoC` | cocotb 15 / 15 (axi_sram 6, plic 6, sys_reset 3) and the crossbar wrapper 6 / 6 pass; the SV `tb_axi_sram` times out; the 36 integration tests the README claims **0 of 36 run** against the current core: `filelist_full.txt` lacks the core's newer files, and elaboration then fails at `cpu_subsystem.sv:160` (`u_icache` has `addr_next`, not `addr`) | its map (SRAM at 0 and 0x1000_0000, peripherals 0x2000_0000, DMA 0x3000_0000) is not the BRV32P or Linux map; its own `plic.sv` is a simplified 8-source one with a flat map, not Linux-compatible; `satp` is a top-level input that nothing drives | everything above, plus the glue is stale | **don't use** as a base; `mmu_axi_bridge.sv` and `cpu_axi_adapter.sv` are patterns worth copying |

Summary: take the PLIC as it is, adapt the MMU, and leave `RISCV_SoC` aside. The larger part of the Linux effort is in
neither: the S-mode CSRs and privilege rules, the A extension, and the timer (section 5).

## 5. What the RTL must gain (stages 2 to 5)

Everything below was needed or was found by booting; "not needed" items were tried absent.

| # | What | Why, and what the boot showed | Stage |
|---|---|---|---|
| 1 | **A extension** (LR, SC, AMO) | `misa` A; Linux needs it. One hart, so a reservation flag in the D-cache path is enough; the bus has no exclusives, so atomics must complete in the cache or as a locked uncached access | 2 |
| 2 | **64-bit `mcycle`, `minstret`** (`mcycleh`, `minstreth`), read-only `cycle`/`instret` (and `h`) aliases, `mcounteren`, `mcountinhibit` | Zicntr; OpenSBI and Linux read them. `time` may be added as a read of `mtime`, or omitted: OpenSBI then emulates `rdtime` on the illegal-instruction trap | 2 |
| 3 | **S and U modes**, `misa` (RW fields can be fixed), `mvendorid`, `marchid`, `mimpid` (the boot reported `marchid` 0x2a, the QEMU default), `mhartid` | OpenSBI's banner and Linux's `/proc/cpuinfo` read them | 2 |
| 4 | **S-mode CSRs**: `sstatus`, `sie`, `sip`, `stvec`, `sscratch`, `sepc`, `scause`, `stval`, `satp`, `scounteren`; `mstatus` MPP, SPP, SIE, SPIE, SUM, MXR, MPRV, TVM, TW, TSR; `medeleg`, `mideleg`; `mip` SSIP, STIP and SEIP writable by M-mode; `SRET`; `SFENCE.VMA`; `WFI` as a legal instruction (it traps today) | the boot log shows `MIDELEG 0x00000222` and `MEDELEG 0x0004b109` set by OpenSBI | 2 |
| 5 | **Exceptions and causes**: ECALL from S (9) and U (8), instruction, load and store page faults (12, 13, 15); `mtvec` direct mode is enough (OpenSBI and Linux use direct) | | 2 |
| 6 | **Sv32**: translation on the I-fetch and the D-access, a TLB, a page-table walker on the bus, A/D by fault (legal), `SFENCE.VMA` | adapt the owner's MMU (section 4); caches must be addressed after translation (or VIPT with care), and `FENCE.I` plus `SFENCE.VMA` must be ordered | 3 |
| 7 | **CLINT or ACLINT** at 0x2001_0000: 64-bit `mtime` (10 MHz by a divider is fine), 64-bit `mtimecmp`, `msip`; drives MTIP and MSIP | OpenSBI reports "aclint-mtimer @ 10000000Hz" and "aclint-mswi"; it sets STIP for the kernel, so the kernel needs no Sstc | 2 |
| 8 | **Bridge decode**: the peripheral bridge today decodes `addr[11:8]` and repeats the 4 KB window through 256 MB; the new slave needs `addr[27:12]` decoded (at least 0x2001 and 0x2002) | | 2 |
| 9 | **Interrupt controller**: none in stage 1. When a source other than the polled console is needed, the owner's PLIC behind a bridge, at the standard layout, with SEIP | the machine boots with GPIO and UART still OR-ed into MEIP and nothing uses it | 5 |
| 10 | **UART**: keep it, but it needs an **RX FIFO** or an interrupt-driven receive. It holds one received byte, so a burst of input keeps only its last byte (overrun); the SBI console is polled by the kernel's HVC thread. `boot_test.sh` therefore types one character at a time (50 ms). A person typing is fine; a paste is not. An ns16550 map (option b) is the alternative if the UART becomes a data path | measured: a whole command sent at once arrived as an empty line | 2 |
| 11 | **RAM**: 128 MiB DDR2 at 0x8000_0000, fully decoded; the 32 KB SRAM at 0 stays and stops aliasing (every other address today aliases it; the interconnect decodes only `addr[31:28] == 2`). The MIG AXI interface and the clock notes of `linux_stage3_ddr2_notes.md` apply: `ui_clk` of about 81 MHz is above the core's present Fmax of 63.9 MHz, so either the core gains from the timing work or an AXI clock converter sits between them; gate the first access on `init_calib_complete` | | 3 |
| 12 | **Loading the images** into DDR: the boot SRAM holds a stub (`a0` hart id, `a1` DT address, `a2` the firmware-info block, jump to 0x8000_0000). The kernel `Image` is 25.9 MB, OpenSBI 270 KB, the initramfs 1.7 MB: at 115,200 baud the kernel alone is about 30 minutes, so the first-stage loader needs SD card, QSPI flash or a JTAG/XVC memory write, not the UART | | 3 |
| 13 | **Power-off and reset**: OpenSBI needs a reset device for a clean stop (SRST). The model uses a finisher at 0x2002_0000 (`syscon-poweroff`); on the board it can be a register that asserts the SoC reset | | 2 |
| 14 | **PMP**: not needed. OpenSBI reported "HART Protection ---" and "PMP Count 0" and booted Linux; its domain lists the whole address space as S/U read-write-execute. PMP only adds isolation of OpenSBI from the kernel | | optional |
| 15 | **Misaligned accesses**: the core's trap on them is kept in the model. Linux booted and probed them as "slow" (OpenSBI emulates them); hardware support is a speed option only | | optional |
| 16 | **Xbrvdsp and the other custom state** (accumulator, address registers, loop, GF and mod-q configuration): Linux does not save it on a context switch, so user code must not use it until a kernel patch exists, or the instructions must trap in U-mode | a risk to settle before stage 5 | 5 |

Not needed: F or D (the kernel and BusyBox are soft-float ilp32), V, hypervisor, Sstc, PMP, a PLIC, ns16550.

## 6. Boot time, footprint

Measured on QEMU v11.1.3 with patches 0001 to 0008, `-M brv32p-linux` (the images are from `linux/build.sh`).

| Item | Value |
|---|---|
| Software versions | Buildroot 2026.08.2, Linux 7.1.13 (the series Buildroot's kernel headers support; 7.3.6 was the newest stable but Buildroot has no 7.3 headers option), OpenSBI 1.8.1 (plus the BRV32P UART driver), BusyBox from Buildroot, musl, GCC 15.3.0 |
| Kernel `Image` | 25.9 MB (rv32 defconfig with `kernel.fragment`; it is large because most drivers of `rv32_defconfig` remain: the fragment removes the buses, but this kernel is not yet cut down to a minimal config) |
| OpenSBI `fw_dynamic.bin` | 270 KB (317 KB with its RW data in memory) |
| initramfs (`rootfs.cpio`, BusyBox, musl, uncompressed) | 1.7 MB |
| Boot to the init process, in instructions | about 0.28 G, from `ICOUNT=1` (one instruction is one virtual nanosecond; the kernel's timestamp at "Run /sbin/init" is 0.283 s). Most of it is the console: OpenSBI busy-waits on the UART for every character at the model's 115,200 baud |
| Boot to a shell and a command, wall clock | about 10 s of kernel time (uptime 9.5 s at the third command), 13 s to power-off, on a shared host |
| RAM at 128 MiB | 97,512 K available to the kernel; `MemFree` 97,556 K at the shell |
| Minimum RAM that booted | **64 MiB** (32 MB available to the kernel). 48 MiB and below did not load: the 25.9 MB `Image` plus its early memory and the initramfs no longer fit after the 4 MiB-aligned load address |

`-m` changes the DT's memory node, so the same DT serves all sizes.

## 7. No-MMU probe (stage 4 feasibility)

[`linux/nommu_probe.sh`](../linux/nommu_probe.sh) builds the same kernel version with the MMU off
([`linux/nommu.fragment`](../linux/nommu.fragment) on `rv32_defconfig`) with the toolchain of `linux/build.sh`, and boots
it on the same machine, OpenSBI and DT.

| Question | Result |
|---|---|
| Does current mainline still support no-MMU on rv32? | Yes. In Linux 7.1.13 `CONFIG_MMU=n` with `CONFIG_ARCH_RV32I`, `CONFIG_NONPORTABLE` and `BINFMT_FLAT` builds from `rv32_defconfig` and a fragment. (Buildroot also ships `qemu_riscv32_nommu_virt_defconfig` with the same approach.) |
| Does it boot? | **Yes, to the init process**: OpenSBI, then the no-MMU kernel in S-mode on the SBI console: "Memory: 119952K/131072K available (3870K kernel code ...)", initramfs unpacked, "Run /sbin/init as init process". The Image is 6.9 MB against 25.9 MB. It stops there because the initramfs holds ELF programs, and a no-MMU kernel runs only flat or FDPIC binaries; a no-MMU userspace needs its own toolchain (uClibc-ng and elf2flt, which Buildroot supports for rv32 but was not built here) |
| Pitfall found | With the MMU off the kernel defaults to `CONFIG_RISCV_M_MODE=y`, a kernel that runs in M-mode without firmware. Under OpenSBI that traps on its first CSR write (`csrw mie`, an illegal instruction in S-mode). Setting `# CONFIG_RISCV_M_MODE is not set` gives an S-mode no-MMU kernel |
| What it saves the RTL | **Sv32 only**: no MMU, no TLB, no page-table walker, no `satp`, no `SFENCE.VMA`, no page-fault causes. **It does not save S-mode**: the booted variant still uses S-mode, the S-mode CSRs and delegation, because OpenSBI runs it as a payload |
| The M-mode-only variant (saves S-mode too) | Not booted. `RISCV_M_MODE` kernels have no SBI, so the console needs a kernel driver for the BRV32P UART (there is none: it is neither ns16550 nor any stock one), plus the CLINT as the clock; the kernel also needs the A extension and the 64-bit counters. The cost is writing a small `earlycon` and serial driver, or choosing option (b) of section 3 (ns16550 map) so that the stock driver works |
| Net | A no-MMU stage 4 is feasible in software today, with about a quarter of the memory (the kernel is 6.9 MB; the 64 MiB minimum of the MMU kernel would fall). The RTL saves Sv32 (stage 3's largest piece); the cost is a flat-binary userspace and no memory protection or demand paging |

## 8. How to reproduce

```
scripts/build.sh              # QEMU with patches 0001 to 0008
linux/build.sh                # Buildroot: toolchain, Linux, OpenSBI, BusyBox initramfs -> linux/out
linux/boot_test.sh            # headless boot, checks, power-off
```

CI runs the same in the `linux-boot` job, with the images cached on the hash of the build script and configs.

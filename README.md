# QEMU_BRV32P

A QEMU machine model, `-M brv32p`, of the BRV32P SoC from
[RISCV_RV32IMC_5stage](https://github.com/BrendanJamesLynskey/RISCV_RV32IMC_5stage): one RV32IMC core in
machine mode with a 32 KB SRAM, a GPIO, a UART and a timer, and no PLIC. The aim is that the same binaries run
on it as on the RTL. There is no Linux and no MMU. Spike stays the ISA reference and the RTL the timing reference.

The repo is a **patch series against a pinned QEMU release**, not a QEMU tree. The release tag is in
[`QEMU_VERSION`](QEMU_VERSION), the one place it is pinned.

## Status

| Step | What | State |
|---|---|---|
| Q0 | [design note](docs/design.md), taken from the RTL | PR `q0-design` |
| Q1 | the machine, the three peripherals, ELF loading with `tohost` exit; tests and CI | PR `q1-machine` |
| Q2 | the custom extensions (Xbrvdsp, GF, mod-q) | not started |
| Q3 | one ELF on QEMU, Spike and RTL in CI | not started |

## Layout

| Path | Contents |
|---|---|
| [`docs/design.md`](docs/design.md) | the design note: memory map, registers, interrupts, boot, how tests end, scope, Q2 and Q3 outline |
| [`docs/pr/q0-design.md`](docs/pr/q0-design.md) | the pull request body |

## Licence

The patches are for QEMU and are GPL-2.0-or-later ([`LICENSE`](LICENSE) is the GPL-2.0 text from QEMU).

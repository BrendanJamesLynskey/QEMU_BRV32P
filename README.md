# QEMU_BRV32P

A QEMU machine model, `-M brv32p`, of the BRV32P SoC from
[RISCV_RV32IMC_5stage](https://github.com/BrendanJamesLynskey/RISCV_RV32IMC_5stage): one RV32IMC core in
machine mode with a 32 KB SRAM, a GPIO, a UART and a timer, and no PLIC. The same binaries run on it as on the
RTL. There is no Linux and no MMU. Spike stays the ISA reference and the RTL the timing reference.

The repo is a **patch series against a pinned QEMU release**, not a QEMU tree. The release tag is in
[`QEMU_VERSION`](QEMU_VERSION), the one place it is pinned.

## Status

| Step | What | State |
|---|---|---|
| Q0 | [design note](docs/design.md), taken from the RTL | PR `q0-design` |
| Q1 | the machine, the three peripherals, ELF loading with `tohost` exit; tests and CI | PR `q1-machine` |
| Q2 | the custom extensions (Xbrvdsp, GF, mod-q) by decodetree, checked against the Spike library | outlined in the design note |
| Q3 | one ELF on QEMU, Spike and RTL in CI | outlined in the design note |

## Build and run

```
scripts/build.sh                   # fetch QEMU at QEMU_VERSION, apply patches/*.patch, build (JOBS=2 by default)
build/qemu/qemu-system-riscv32 -M brv32p -nographic -kernel test.elf
```

An ELF given with `-kernel` is loaded where it is linked and started at its entry point. If it has a `tohost`
symbol, a store to it ends the run with the riscv-tests exit status (0 for a pass). A raw image runs with
`-device loader,file=fw.bin,addr=0` from address 0, the RTL's reset PC. The UART is `-serial`; the clock the
UART and timer count in is `-global riscv.brv32p.timer.clock-frequency=...` (and `.uart.`), 100 MHz by
default; `-icount shift=3` makes a run deterministic.

The GPIO pins are the QOM properties `gpio-in` (writable) and `gpio-out` of `/machine/gpio`.

## Layout

| Path | Contents |
|---|---|
| [`docs/design.md`](docs/design.md) | the design note: memory map, registers, interrupts, boot, how tests end, scope |
| [`patches/`](patches) | the series: `target/riscv` CPU, `hw/char`, `hw/gpio`, `hw/timer`, `hw/riscv` machine; GPL-2.0-or-later |
| [`scripts/build.sh`](scripts/build.sh) | fetch the pinned tag shallowly, apply the patches, configure a minimal `riscv32-softmmu`, make |
| [`tests/run_isa.sh`](tests/run_isa.sh) | the core repo's ISA tests (riscv-tests, directed) and rv32mi, run through `tohost` |
| [`tests/run_machine.py`](tests/run_machine.py) | SoC firmware, timer, UART and GPIO tests |
| [`tests/machine/`](tests/machine) | the machine tests written for the model: [`timer.S`](tests/machine/timer.S), [`uart.S`](tests/machine/uart.S), [`gpio.S`](tests/machine/gpio.S) |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | build QEMU (cached), install the RISC-V GCC as the core repo's CI does, run the tests, upload a report |
| [`docs/pr/`](docs/pr) | the pull request bodies |

## Tests

`tests/run_isa.sh` and `tests/run_machine.py` need the core repo (`CORE_REPO`, default `../RISCV_RV32IMC_5stage`)
for its env, linker script, directed tests and firmware generator, and `riscv64-unknown-elf-gcc`. They write
`tests/build/*/results.txt`.

## Results

On QEMU `v11.1.3` plus the patches: 118 / 118 of the ISA tests run (rv32ui 41, rv32um 8, rv32uc 1, rv32ui-c 40,
rv32um-c 8, the core repo's directed tests without custom instructions 6, rv32mi 14), and 4 / 4 of the machine
tests (SoC firmware, timer, UART, GPIO). The 12 tests not run are listed with their reasons in
[`tests/run_isa.sh`](tests/run_isa.sh).

## Licence

The patches are for QEMU and are GPL-2.0-or-later ([`LICENSE`](LICENSE) is the GPL-2.0 text from QEMU).

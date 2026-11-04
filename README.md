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
| Q2 | the custom extensions (Xbrvdsp, GF, mod-q) by decodetree, checked against the Spike library | PR `q2-extensions`: patch 0007, 126 ISA tests run, 11 in lockstep with Spike |
| Q3 | one ELF on QEMU, Spike and RTL in CI | PR `q3-three-platforms`: 22 programs built once; [`docs/results_q3.md`](docs/results_q3.md) |

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
| [`patches/`](patches) | the series: `target/riscv` CPU, `hw/char`, `hw/gpio`, `hw/timer`, `hw/riscv` machine, the custom extensions (0007); GPL-2.0-or-later |
| [`scripts/build.sh`](scripts/build.sh) | fetch the pinned tag shallowly, apply the patches, configure a minimal `riscv32-softmmu`, make |
| [`tests/run_isa.sh`](tests/run_isa.sh) | the core repo's ISA tests (riscv-tests, directed) and rv32mi, run through `tohost` |
| [`tests/run_machine.py`](tests/run_machine.py) | SoC firmware, timer, UART and GPIO tests |
| [`tests/run_lockstep.sh`](tests/run_lockstep.sh) | the custom-instruction tests on QEMU and on Spike (with the core repo's `libxbrvdsp.so`), compared instruction by instruction |
| [`tests/lockstep_qemu.py`](tests/lockstep_qemu.py) | the comparison: QEMU's `execlog` plugin against Spike's commit log |
| [`tests/run_three.sh`](tests/run_three.sh) | one ELF per program on QEMU, Spike and the RTL (Icarus, the core repo's `tb_isa.v`), compared: verdict, UART, commit logs |
| [`tests/three_compare.py`](tests/three_compare.py) | the comparison, and `--selftest`, which corrupts copies of the results and expects each to be caught |
| [`tests/three/`](tests/three) | the programs and helpers written for Q3: [`dsp_small.c`](tests/three/dsp_small.c) with [`build_dsp_small.sh`](tests/three/build_dsp_small.sh), [`firmware_tohost.py`](tests/three/firmware_tohost.py), [`uart_hello.S`](tests/three/uart_hello.S), [`uart_mon.v`](tests/three/uart_mon.v) |
| [`tests/gen_random.py`](tests/gen_random.py) | writes the randomised operand tests (`rand_alu`, `rand_gf`, `rand_mq`, `rand_agu`, `rand_loop`) |
| [`tests/machine/`](tests/machine) | the machine tests written for the model: [`timer.S`](tests/machine/timer.S), [`uart.S`](tests/machine/uart.S), [`gpio.S`](tests/machine/gpio.S) |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | build QEMU (cached), install the RISC-V GCC as the core repo's CI does, run the tests, run the three platforms, upload the reports |
| [`docs/results_q3.md`](docs/results_q3.md) | the Q3 table: every program, the platforms, the agreement, instructions compared, RTL cycles, SHA-256 of the ELFs |
| [`docs/pr/`](docs/pr) | the pull request bodies |

## Tests

`tests/run_isa.sh` and `tests/run_machine.py` need the core repo (`CORE_REPO`, default `../RISCV_RV32IMC_5stage`)
for its env, linker script, directed tests and firmware generator, and `riscv64-unknown-elf-gcc`. They write
`tests/build/*/results.txt`.

`tests/run_lockstep.sh` also needs Spike (`SPIKE`, built at the revision the core repo's CI pins) and the core
repo's `libxbrvdsp.so` (`XBRVDSP_LIB`, from `tools/spike_xbrvdsp/build.sh`), and the `execlog` plugin that
`scripts/build.sh` builds with QEMU. It runs the custom-instruction tests on both simulators and compares them
instruction by instruction (pc, encoding, register written); a mismatch fails the test.

## Results

On QEMU `v11.1.3` plus the seven patches (core repo at `bc75bf8`): 126 / 126 of the ISA tests run (rv32ui 41,
rv32um 8, rv32uc 1, rv32ui-c 40, rv32um-c 8, rv32mi 14, and the core repo's 14 directed tests: the 6 without
custom instructions, the 7 that use Xbrvdsp, GF or mod-q, and `periph_uncached`, added to the core repo after
Q1), 4 / 4 of the machine tests (SoC firmware, timer, UART, GPIO), and 11 / 11 of the lockstep tests against
Spike (the 6 directed tests Spike can run, and 5 randomised operand tests; 362,689 instructions compared,
79,100 of them custom). The 5 ISA tests not run are listed with their reasons in
[`tests/run_isa.sh`](tests/run_isa.sh).

## One binary, three platforms

Step Q3 builds each of 22 programs once and runs that ELF on the QEMU model, on Spike (with the core repo's
`libxbrvdsp.so`) and on the RTL (the core repo's testbench under Icarus Verilog), and compares them:
the verdict (`tohost`) on all 22, the UART output on the two that print, and the commit log, instruction
by instruction, for each pair that can log it. The programs are the core repo's 14 directed tests, the 5
randomised operand tests, a real program (`dsp_small`: its FIR with `mac`, `dmac`, the address generators and the
hardware loop, and its ML-KEM NTT with the mod-q unit, 116,432 instructions), the SoC firmware (made to end through
`tohost` without changing the core repo) and a UART test. All 22 agree on all three platforms where they run:
18 programs have commit logs compared (480,005 instructions in all), and the 4 that depend on time or the UART
(`dsp_irq`, `timer_irq`, `periph_uncached`, `uart_hello`) are compared on the verdict and the output. Spike has no
timer or UART, so five programs run on QEMU and the RTL only. Cycle counts are the RTL's alone. The same ELF
can be loaded on the board through the core repo's flow. See [`docs/results_q3.md`](docs/results_q3.md).

## Licence

The patches are for QEMU and are GPL-2.0-or-later ([`LICENSE`](LICENSE) is the GPL-2.0 text from QEMU).

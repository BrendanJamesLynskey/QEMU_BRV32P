# Q1: the BRV32P machine for QEMU

On top of Q0. Adds the patch series against QEMU `v11.1.3` (the tag is pinned in `QEMU_VERSION`), the build
script, the tests and the CI workflow.

## The series (`patches/`)

1. `target/riscv`: the `brv32p` CPU (RV32IMC, Zicsr, Zifencei, Zbkb, Zbkc, Zbkx, Zknd, Zkne, Zknh; machine mode only).
2. `hw/char`: the UART, register-exact to `rtl/periph/uart.v`, with the frame timing, the overrun flag and a chardev.
3. `hw/gpio`: the GPIO, with its pins as qdev lines and the QOM properties `gpio-in` and `gpio-out`.
4. `hw/timer`: the timer, brought up to date from virtual time on each access, with a QEMU timer for the match.
5. `hw/riscv`: the machine `brv32p` (SRAM at 0 and 0x80000000, peripherals at 0x20000000, MEIP = GPIO or UART,
   MTIP = timer, ELF loading, the `tohost` exit).
6. `target/riscv`: an internal CPU option that makes misaligned loads and stores trap, as the core does.

## Tests (see the CI run)

* `tests/run_isa.sh`: the core repo's riscv-tests suites (rv32ui, rv32um, rv32uc, and the C-enabled variants),
  its directed tests that use no custom instruction, and the upstream rv32mi suite, each ending through `tohost`.
* `tests/run_machine.py`: the SoC firmware (UART byte, GPIO pattern, registers, final `ECALL`), and a timer, a UART
  and a GPIO test written for the model.

## Not covered (see `docs/design.md`)

Cycle timing, caches and AXI; the custom extensions (step Q2); aliases of the SRAM other than 0x0 and 0x80000000.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

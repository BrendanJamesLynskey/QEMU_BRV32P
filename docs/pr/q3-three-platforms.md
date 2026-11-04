# Q3: one ELF on QEMU, Spike and the RTL

Each program is built once and the same ELF is run on the QEMU model (`-M brv32p`), on Spike (with the core
repo's `libxbrvdsp.so`) and on the RTL (the core repo's `tb_isa.v` under Icarus Verilog). The results are
compared by `tests/run_three.sh` and `tests/three_compare.py`; a disagreement fails the CI job.

## Result

22 / 22 programs agree and pass on every platform that runs them (CI run on `q3-three-platforms`, job
`three-platforms`; the table is [`docs/results_q3.md`](docs/results_q3.md), with the SHA-256 of every ELF).

| | |
|---|---|
| Programs | the core repo's 14 directed tests, its 5 randomised operand tests (from Q2), `dsp_small`, `firmware`, `uart_hello` |
| Verdict (`tohost`) | agrees on all 22 |
| UART output | agrees on `firmware` (`H`) and `uart_hello` (a line); the rest print nothing |
| Commit logs | 18 programs, 480,005 instructions: QEMU against Spike and RTL against Spike on 17 (all but `firmware`), RTL against QEMU on all 18 |
| Not compared by commit log | `dsp_irq`, `timer_irq` (interrupt timing), `periph_uncached` (reads the timer count), `uart_hello` (polls the transmitter) |
| Not run on Spike | those four and `firmware`: Spike has no timer and no UART |
| Cycles | the RTL's, in the table; the model has no timing |

No disagreement between the three platforms was found.

## What is new

* **`tests/run_three.sh`**: builds each program once (the core repo's env and linker script, unchanged), runs
  it on the three platforms, prints one line per program (`PASS`, the platforms, the instructions compared, the
  RTL cycles) and writes the table.
* **`tests/three_compare.py`**: compares the verdicts, the UART output and the commit logs of each pair.
  `--selftest` corrupts copies of one program's results (a verdict, a UART byte, a register in the RTL trace,
  one in the Spike log) and fails unless each is caught; CI runs it. RTL against QEMU reuses
  `tests/lockstep_qemu.py`, which now takes `--ignore-pc` for a result that differs by design (the firmware's
  one read of `mcycle`).
* **`dsp_small`**, the real program: the core repo's FIR (plain, `mac`, `dmac`, the address generators, the
  hardware loop `lp.setup` with `dmac.lp`), energy and ML-KEM NTT kernels (the reference and the mod-q unit),
  compiled unchanged from `tests/bench`, 116,432 instructions. The benchmark as a whole is 38 KB and links for
  64 KB of SRAM, so only the kernels are linked, with a `main` of its own, and the core repo's linker script has
  its two top-of-memory numbers lowered by 32 KB by `sed` at build time.
* **`firmware`**: the SoC firmware, made to end through `tohost` without changing the core repo: its
  instruction words up to the final `ECALL`, a check of the registers it computes, and the store to `tohost`.
* **`uart_hello`**, and **`uart_mon.v`**, a second top-level module for the RTL run that decodes `tb_isa`'s
  `uart_tx` pin (`tb_isa.v` is not changed).
* **CI**: a job `three-platforms` (needs `test` and `spike`), with the core repo checked out at its pinned
  commit `bc75bf8`, Icarus installed as the core repo's CI does, uploading the ELFs, the logs and the table.
  The workflow now runs on pull requests and on pushes to `main`, not on every push to a branch, and a newer
  run of the same ref cancels the older one.
* **Docs**: design note sections 11 and 12, the table, the README.
* A one-line fix to the Q2 PR body's per-instruction counts (`docs/pr/q2-extensions.md`).

The board (Nexys) run is not part of this step; the same ELF can be loaded on it through the core repo's flow.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

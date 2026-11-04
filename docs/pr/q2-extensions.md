# Q2: the custom extensions for QEMU

On top of Q1. The `brv32p` CPU now runs every custom instruction of the core (Xbrvdsp, the packed GF(2^8)
multiply and the mod-q unit, on custom-0 and custom-1), with the state they add, and the result of each
instruction is checked against the core repo's Spike model (`libxbrvdsp.so`) instruction by instruction.
Zk/Zbk, already upstream, is untouched.

## The patch (`patches/0007`)

A vendor extension of `brv32p` only (the cfg flag `ext_xbrvdsp`, set in the CPU's definition, `xbrvdsp` in the
ISA string), in the way QEMU's other vendor extensions are done:

* `target/riscv/xbrvdsp.decode`: 45 patterns, added to the vendor decoder table in `translate.c`, gated on the
  flag. Every field the RTL decoder requires to be zero is fixed to zero, so the same words are illegal.
* `tcg/insn_trans/trans_xbrvdsp.c.inc`: picks the helper and moves registers and pc.
* `tcg/xbrvdsp_helper.c`: the arithmetic (accumulate and rounded saturating reads, saturating and packed halves,
  GF(2^8), Montgomery mod q, address-register stepping with the bit-reversed mode, the loop count), a
  transcription of the Spike model.
* State in `CPURISCVState`: the 40-bit accumulator, `ar0` to `ar3` (address, stride, bit-reversed mode), `lc`,
  `lp_start`, the GF polynomial, `q`, `q'`, `zeta`. Reset as the RTL resets it; migrated in a `cpu/xbrvdsp`
  subsection.
* Hardware loop: `mac.lp`, `dmac.lp`, `msu.lp` and `lp.end` end the translation block and take the next pc at run
  time from `lc` and `lp_start`. An interrupt is taken between instructions, so a loop-ending instruction either
  completes or has not started (`mepc` is its address, and after `mret` it runs once), as the RTL's squash gives.
  A trap from inside the body has `mepc` = the trapping instruction. See `docs/design.md` section 9.
* Address-register loads do the load first and step the register after, so a misaligned one (which traps)
  leaves it unchanged.

## Tests

CI on this branch (QEMU `v11.1.3` plus seven patches; core repo at `bc75bf8`, Spike at the core repo's pinned
revision):

| Suite | Passed | Not run |
|---|---|---|
| ISA: rv32ui, rv32um, rv32uc, rv32ui-c, rv32um-c | 41, 8, 1, 40, 8 | `ma_data` (x2), `fence_i` (as before) |
| ISA: rv32mi | 14 / 14 | `pmpaddr`, `instret_overflow` (as before) |
| ISA: the core repo's directed tests | 14 / 14 | |
| machine: SoC firmware, timer, UART, GPIO | 4 / 4 | |
| lockstep with Spike | 11 / 11 | |

That is 126 / 126 ISA tests run and 5 not run. The 7 tests Q1 skipped (`dsp_agu`, `dsp_irq`, `dsp_loop`,
`dsp_mac`, `gf`, `mq`, `mul_use`) now run and pass. The 14th directed test, `periph_uncached`, came with the
core repo's D-cache fix after Q1; it runs at 16 ns per instruction (see the design note).

The lockstep (`tests/run_lockstep.sh`, `tests/lockstep_qemu.py`) runs each test on QEMU, with its `execlog`
plugin, and on Spike with `libxbrvdsp.so`, and compares pc, encoding and register written for every retired
instruction. A mismatch fails the test. It covers the 6 directed tests Spike can run (`dsp_irq` needs the
timer and checks itself in the ISA run) and 5 randomised operand tests written by `tests/gen_random.py`
(256 operand sets per instruction):

| Test | Instructions compared | of them custom |
|---|---|---|
| dsp_agu, dsp_loop, dsp_mac, gf, mq, mul_use | 69,915 / 276 / 2,081 / 99 / 203 / 86 | 1,095 / 112 / 664 / 16 / 36 / 3 |
| rand_alu | 103,574 | 30,592 |
| rand_gf | 26,778 | 3,353 |
| rand_mq | 147,700 | 36,890 |
| rand_agu | 3,566 | 1,232 |
| rand_loop | 8,411 | 5,107 |

Every custom instruction (all 45 encodings) is compared at least 3 times in the directed tests and 88 to 12,000
times in the random ones.

## CI

`test` (the Q1 job) now also builds QEMU's `execlog` plugin, and saves the QEMU build as soon as it is built. A
new `spike` job builds Spike at the core repo's pinned `SPIKE_REV` (cached), and a new `lockstep` job builds
`libxbrvdsp.so` from the checked-out core repo and runs the lockstep, uploading the logs and results.

## Findings

No disagreement between the RTL, the Spike model and the specs was found in the decode, reset values, rounding,
saturation, bit-reversed step, loop count or mod-q reductions. Corner cases the tests do not reach (a `lp_start`
with bit 0 set) are listed in `docs/design.md`. The design note's finding that peripheral registers go through the
D-cache is marked fixed in core PR #30.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

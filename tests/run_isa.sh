#!/usr/bin/env bash
# run_isa.sh — build the core repo's ISA tests and run them on -M brv32p.
#
# Usage: tests/run_isa.sh [suite ...]    suites: rv32ui rv32um rv32uc rv32ui-c rv32um-c directed rv32mi
#        (no arguments: all of them)
# Env:   QEMU        qemu-system-riscv32 (default build/qemu/qemu-system-riscv32)
#        CORE_REPO   a checkout of RISCV_RV32IMC_5stage (default ../RISCV_RV32IMC_5stage)
#        RISCV_TESTS a riscv-tests checkout with its env/ submodule (default
#                    $CORE_REPO/tests/isa/riscv-tests; cloned there if it is missing)
#        CROSS       toolchain prefix (default riscv64-unknown-elf-)
#
# The suites are built as the core repo's tests/isa/run_isa.sh builds them
# (same -march, same env and linker script), and each ends through its store
# to tohost: exit status 0 is a pass, N is a failure in test case N. rv32mi
# is not in the core repo's runner: it needs the upstream machine-mode env, so
# it is built with that env and runs on the model only.
# Output: tests/build/isa/results.txt, one line per test, and a total.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
QEMU="${QEMU:-$ROOT/build/qemu/qemu-system-riscv32}"
CORE_REPO="${CORE_REPO:-$ROOT/../RISCV_RV32IMC_5stage}"
RISCV_TESTS="${RISCV_TESTS:-$CORE_REPO/tests/isa/riscv-tests}"
RISCV_TESTS_REV="${RISCV_TESTS_REV:-3df703c}"   # as the core repo's runner
CROSS="${CROSS:-riscv64-unknown-elf-}"
B="$ROOT/tests/build/isa"
mkdir -p "$B"

[ -x "$QEMU" ] || { echo "run_isa.sh: no QEMU at $QEMU (scripts/build.sh builds it)" >&2; exit 2; }
if [ ! -d "$RISCV_TESTS/isa" ]; then
  git clone -q https://github.com/riscv-software-src/riscv-tests.git "$RISCV_TESTS"
  git -C "$RISCV_TESTS" checkout -q "$RISCV_TESTS_REV"
fi
if [ ! -f "$RISCV_TESTS/env/p/riscv_test.h" ]; then
  git -C "$RISCV_TESTS" submodule update -q --init env
fi

declare -A MARCH=( [rv32ui]=rv32i_zicsr_zifencei [rv32um]=rv32im_zicsr_zifencei [rv32uc]=rv32ic_zicsr_zifencei
                   [rv32ui-c]=rv32ic_zicsr_zifencei [rv32um-c]=rv32imc_zicsr_zifencei
                   [rv32mi]=rv32imc_zicsr_zifencei
                   [directed]=rv32imc_zicsr_zifencei_zbkb_zbkc_zbkx_zknh_zkne_zknd )
declare -A SRC=( [rv32ui]="$RISCV_TESTS/isa/rv32ui" [rv32um]="$RISCV_TESTS/isa/rv32um" [rv32uc]="$RISCV_TESTS/isa/rv32uc"
                 [rv32ui-c]="$RISCV_TESTS/isa/rv32ui" [rv32um-c]="$RISCV_TESTS/isa/rv32um"
                 [rv32mi]="$RISCV_TESTS/isa/rv32mi" [directed]="$CORE_REPO/tests/directed" )
# The core repo's own env and linker script, except for rv32mi
ENV_DIR="$CORE_REPO/tests/isa/env"
declare -A ENV_INC=( [rv32mi]="$RISCV_TESTS/env/p" )
declare -A LD=( [rv32mi]="$RISCV_TESTS/env/p/link.ld" )
SUITES=(rv32ui rv32um rv32uc rv32ui-c rv32um-c directed rv32mi)
[ $# -gt 0 ] && SUITES=("$@")

# Not run, with the reason; the first group is the core repo's own list. (The tests that use the
# custom Xbrvdsp, GF(2^8) and mod-q instructions run since step Q2; tests/run_lockstep.sh also
# compares them with Spike.)
declare -A SKIP=(
  [rv32ui/ma_data]="needs misaligned access in hardware; the core and the model trap (see directed/misaligned)"
  [rv32ui-c/ma_data]="as rv32ui/ma_data"
  [rv32ui-c/fence_i]="patches code assuming 32-bit encodings; assembled with C it overwrites compressed code"
  # rv32mi tests of features the core does not have (the model fails them too)
  [rv32mi/pmpaddr]="needs PMP; the core has none (fails at test case 1 on the model)"
  [rv32mi/instret_overflow]="needs a writable minstret and minstreth; the core cannot write minstret, and the model's counts instructions (fails at test case 2)"
)

# Virtual time per instruction is 2^shift ns (default 8 ns). The timer ticks every 10 ns, so with the
# default two back-to-back reads of its count can fall in the same tick (the RTL's loads take several
# cycles): periph_uncached, which needs them to differ, runs at 16 ns per instruction.
declare -A SHIFT=( [directed/periph_uncached]=4 )

: > "$B/results.txt"
total=0; fails=0; skipped=0
for suite in "${SUITES[@]}"; do
  [ -n "${SRC[$suite]:-}" ] || { echo "unknown suite $suite" >&2; exit 2; }
  scount=0; spass=0; sskip=0
  for f in "${SRC[$suite]}"/*.S; do
    name="$(basename "$f" .S)"; t="$suite/$name"
    if [ -n "${SKIP[$t]:-}" ]; then
      printf '%-24s N/A: %s\n' "$t" "${SKIP[$t]}" >> "$B/results.txt"; sskip=$((sskip + 1)); continue
    fi
    out="$B/$suite-$name"
    inc=(-I "$ENV_DIR"); ld="$ENV_DIR/link.ld"
    [ -n "${ENV_INC[$suite]:-}" ] && { inc=(-I "${ENV_INC[$suite]}"); ld="${LD[$suite]}"; }
    if ! "${CROSS}gcc" -march="${MARCH[$suite]}" -mabi=ilp32 -static -mcmodel=medany -nostdlib -nostartfiles \
         "${inc[@]}" -I "$RISCV_TESTS/isa/macros/scalar" -T "$ld" "$f" -o "$out.elf" 2> "$out.build.log"; then
      printf '%-24s BUILD FAIL (see %s)\n' "$t" "$out.build.log" | tee -a "$B/results.txt"
      scount=$((scount + 1)); fails=$((fails + 1)); continue
    fi
    timeout 60 "$QEMU" -M brv32p -display none -monitor none -serial none -no-reboot \
      -icount shift=${SHIFT[$t]:-3} -kernel "$out.elf" > "$out.log" 2>&1
    rc=$?
    scount=$((scount + 1))
    case $rc in
      0)   spass=$((spass + 1)); printf '%-24s PASS\n' "$t" >> "$B/results.txt" ;;
      124) fails=$((fails + 1)); printf '%-24s FAIL timeout\n' "$t" | tee -a "$B/results.txt" ;;
      *)   fails=$((fails + 1)); printf '%-24s FAIL test case %d\n' "$t" "$rc" | tee -a "$B/results.txt" ;;
    esac
  done
  printf 'suite %-10s %d / %d passed, %d not run\n' "$suite" "$spass" "$scount" "$sskip" | tee -a "$B/results.txt"
  total=$((total + scount)); skipped=$((skipped + sskip))
done
echo "$((total - fails)) / $total passed, $skipped not run" | tee -a "$B/results.txt"
[ "$fails" -eq 0 ]

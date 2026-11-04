#!/usr/bin/env bash
# run_lockstep.sh — run the custom-instruction tests on QEMU and on Spike (with
# the core repo's libxbrvdsp.so) and compare them instruction by instruction.
#
# Usage: tests/run_lockstep.sh [test ...]     e.g. dsp_mac rand_mq    (no arguments: all)
# Tests: the core repo's tests/directed/{dsp_agu,dsp_loop,dsp_mac,gf,mq,mul_use}.S, and the
#        randomised operand tests tests/gen_random.py writes (rand_alu, rand_gf, rand_mq,
#        rand_agu, rand_loop). dsp_irq needs the timer, which Spike does not have; it
#        checks itself and runs in tests/run_isa.sh.
# Env:   QEMU        qemu-system-riscv32 (default build/qemu/qemu-system-riscv32)
#        PLUGIN      QEMU's libexeclog.so (default build/qemu/contrib/plugins/libexeclog.so)
#        SPIKE       spike (default: on the PATH)
#        XBRVDSP_LIB the core repo's libxbrvdsp.so (tools/spike_xbrvdsp/build.sh)
#        CORE_REPO, RISCV_TESTS, CROSS   as for tests/run_isa.sh
#
# Each test is built as the core repo's runner builds the directed tests (same -march, env and
# linker script) and run with its entry at 0x80000000. QEMU logs every instruction and the
# registers it changes (the execlog plugin, with `-d plugin,int`); Spike logs its commits.
# tests/lockstep_qemu.py compares the two: pc, instruction and register writeback, and so every
# result of every custom instruction, since each ends up in a register. A mismatch fails the test.
# Output: tests/build/lockstep/results.txt, and the logs beside it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
QEMU="${QEMU:-$ROOT/build/qemu/qemu-system-riscv32}"
PLUGIN="${PLUGIN:-$ROOT/build/qemu/contrib/plugins/libexeclog.so}"
SPIKE="${SPIKE:-$(command -v spike || true)}"
CORE_REPO="${CORE_REPO:-$ROOT/../RISCV_RV32IMC_5stage}"
XBRVDSP_LIB="${XBRVDSP_LIB:-$CORE_REPO/tools/spike_xbrvdsp/build/libxbrvdsp.so}"
RISCV_TESTS="${RISCV_TESTS:-$CORE_REPO/tests/isa/riscv-tests}"
CROSS="${CROSS:-riscv64-unknown-elf-}"
MARCH=rv32imc_zicsr_zifencei_zbkb_zbkc_zbkx_zknh_zkne_zknd    # as the core repo's directed tests
B="$ROOT/tests/build/lockstep"
mkdir -p "$B"

for f in "$QEMU" "$PLUGIN" "$SPIKE" "$XBRVDSP_LIB"; do
  [ -x "$f" ] || [ -f "$f" ] || { echo "run_lockstep.sh: missing $f" >&2; exit 2; }
done
[ -f "$RISCV_TESTS/isa/macros/scalar/test_macros.h" ] || { echo "run_lockstep.sh: no riscv-tests at $RISCV_TESTS" >&2; exit 2; }

DIRECTED=(dsp_agu dsp_loop dsp_mac gf mq mul_use)
RANDOM_T=(rand_alu rand_gf rand_mq rand_agu rand_loop)
python3 "$HERE/gen_random.py" "$B" > /dev/null
tests=("$@")
[ ${#tests[@]} -eq 0 ] && tests=("${DIRECTED[@]}" "${RANDOM_T[@]}")

# QEMU's execlog plugin: the 31 general registers (their gdb names), nothing else
REGS=(ra sp gp tp t0 t1 t2 fp s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6)
PLUGIN_ARGS="$PLUGIN"
for r in "${REGS[@]}"; do PLUGIN_ARGS+=",reg=$r"; done

: > "$B/results.txt"
total=0; fails=0
for name in "${tests[@]}"; do
  if [ -f "$B/$name.S" ]; then src="$B/$name.S"; else src="$CORE_REPO/tests/directed/$name.S"; fi
  [ -f "$src" ] || { echo "run_lockstep.sh: no test $name" >&2; exit 2; }
  out="$B/$name"; t="lockstep/$name"
  total=$((total + 1))
  if ! "${CROSS}gcc" -march="$MARCH" -mabi=ilp32 -static -mcmodel=medany -nostdlib -nostartfiles \
       -I "$CORE_REPO/tests/isa/env" -I "$RISCV_TESTS/isa/macros/scalar" -T "$CORE_REPO/tests/isa/env/link.ld" \
       "$src" -o "$out.elf" 2> "$out.build.log"; then
    printf '%-24s BUILD FAIL (see %s)\n' "$t" "$out.build.log" | tee -a "$B/results.txt"; fails=$((fails + 1)); continue
  fi
  tohost="$("${CROSS}nm" "$out.elf" | awk '$3 == "tohost" { print $1 }')"
  # First without the trace: a test that never reaches tohost must not fill the disk with a log
  timeout 30 "$QEMU" -M brv32p -display none -monitor none -serial none -no-reboot -kernel "$out.elf" \
    > "$out.plain.out" 2>&1
  prc=$?
  if [ "$prc" -eq 124 ]; then
    fails=$((fails + 1)); printf '%-24s FAIL timeout (QEMU does not reach tohost in 30 s)\n' "$t" | tee -a "$B/results.txt"; continue
  fi
  # The traced run, with the log capped (500 MB) and a time limit
  ( ulimit -f 1000000; timeout 120 "$QEMU" -M brv32p -display none -monitor none -serial none -no-reboot -kernel "$out.elf" \
      -plugin "$PLUGIN_ARGS" -d plugin,int -D "$out.qemu" > "$out.qemu.out" 2>&1 )
  qrc=$?
  ( ulimit -f 1000000; timeout 120 "$SPIKE" --isa="$MARCH" --extlib="$XBRVDSP_LIB" --extension=xbrvdsp \
      -m0x80000000:0x8000 --log-commits "$out.elf" 2> "$out.spike" > /dev/null )
  echo "  $t: QEMU exit $prc plain / $qrc traced; logs $(stat -c %s "$out.qemu") and $(stat -c %s "$out.spike") bytes"
  res="$(python3 "$HERE/lockstep_qemu.py" "$out.qemu" "$out.spike" --tohost "$tohost" 2>&1 | tail -n 12)"
  last="$(printf '%s\n' "$res" | tail -n 1)"
  case "$last" in
    MATCH*) if [ "$qrc" -eq 0 ]; then
              printf '%-24s PASS  [lockstep: %s]\n' "$t" "$last" >> "$B/results.txt"
            else
              fails=$((fails + 1)); printf '%-24s FAIL test case %d  [lockstep: %s]\n' "$t" "$qrc" "$last" | tee -a "$B/results.txt"
            fi ;;
    *)      fails=$((fails + 1))
            printf '%-24s FAIL lockstep (QEMU exit %d)\n' "$t" "$qrc" | tee -a "$B/results.txt"
            printf '%s\n' "$res" | sed 's/^/    /' | tee -a "$B/results.txt"
            tail -n 3 "$out.qemu.out" | sed 's/^/    qemu: /' | tee -a "$B/results.txt" ;;
  esac
done
printf 'suite %-10s %d / %d passed, 0 not run\n' lockstep "$((total - fails))" "$total" | tee -a "$B/results.txt"
echo "$((total - fails)) / $total passed, 0 not run" | tee -a "$B/results.txt"
[ "$fails" -eq 0 ]

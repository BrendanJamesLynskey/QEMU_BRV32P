#!/usr/bin/env bash
# run_three.sh - one ELF, three platforms (step Q3): build each program once, run it on the QEMU model,
# on Spike (with libxbrvdsp.so) and on the RTL (the core repo's tb_isa.v under Icarus), and compare.
#
# Usage: tests/run_three.sh [program ...]     (no arguments: all of them; names are in PROGRAMS below)
# Env:   QEMU, PLUGIN, SPIKE, XBRVDSP_LIB, CORE_REPO, RISCV_TESTS, CROSS   as for tests/run_lockstep.sh
#        IVERILOG, VVP    the Icarus Verilog tools (default: on the PATH)
# Output: tests/build/three/ - per program <name>.elf and the logs of each platform; sha256.txt (the
#        SHA-256 of every ELF); results.txt, one line per program; results_q3.md, the table for
#        docs/results_q3.md. tests/three_compare.py does the comparing (and --selftest checks the check).
#
# Programs (what is built, what each platform can run):
#   the core repo's 14 directed tests (tests/directed) and 5 randomised operand tests (tests/gen_random.py),
#   built as the core repo's runner builds them, with its env and linker script unchanged;
#   dsp_small     the core repo's FIR and ML-KEM kernels (tests/three/dsp_small.c);
#   firmware      the SoC firmware, as an ELF that ends through tohost (tests/three/firmware_tohost.py);
#   uart_hello    prints a line on the UART (tests/three/uart_hello.S).
# Spike has no timer and no UART, so dsp_irq, timer_irq, periph_uncached, firmware and uart_hello run on
# QEMU and the RTL only. Interrupt timing, timer reads and UART polling make those programs' instruction
# streams differ between QEMU and the RTL by design, so they are compared on the verdict and the UART
# output, and on the commit log only where the stream is the same (firmware: all but one mcycle read).
# Exit status 0 only if every program passes and every comparison matches.
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
IVERILOG="${IVERILOG:-iverilog}"; VVP="${VVP:-vvp}"
MARCH=rv32imc_zicsr_zifencei_zbkb_zbkc_zbkx_zknh_zkne_zknd    # as the core repo's directed tests
B="$ROOT/tests/build/three"
mkdir -p "$B"

for f in "$QEMU" "$PLUGIN" "$SPIKE" "$XBRVDSP_LIB"; do
  [ -x "$f" ] || [ -f "$f" ] || { echo "run_three.sh: missing $f" >&2; exit 2; }
done
[ -f "$RISCV_TESTS/isa/macros/scalar/test_macros.h" ] || { echo "run_three.sh: no riscv-tests at $RISCV_TESTS" >&2; exit 2; }
command -v "$IVERILOG" > /dev/null || { echo "run_three.sh: no iverilog" >&2; exit 2; }

# name:kind     kind = directed (core repo), random (gen_random.py), local (tests/three)
PROGRAMS=(csr_use:directed dsp_agu:directed dsp_irq:directed dsp_loop:directed dsp_mac:directed
          fence_i_fill:directed fence_i_warm:directed gf:directed misaligned:directed mq:directed
          mul_use:directed periph_uncached:directed timer_irq:directed zk:directed
          rand_alu:random rand_gf:random rand_mq:random rand_agu:random rand_loop:random
          dsp_small:local firmware:local uart_hello:local)
NO_SPIKE=" dsp_irq timer_irq periph_uncached firmware uart_hello "      # a timer or a UART, which Spike lacks
NO_TRACE=" dsp_irq timer_irq periph_uncached uart_hello "                # instruction streams differ by design
EXT=" dsp_agu dsp_irq dsp_loop dsp_mac gf mq mul_use rand_alu rand_gf rand_mq rand_agu rand_loop dsp_small "  # Xbrvdsp, GF, mod-q
declare -A SHIFT=( [periph_uncached]=4 )          # 16 ns per instruction, as tests/run_isa.sh

selected=("$@")
want() { [ ${#selected[@]} -eq 0 ] && return 0; local s; for s in "${selected[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

python3 "$HERE/gen_random.py" "$B" > /dev/null
python3 "$HERE/three/firmware_tohost.py" "$CORE_REPO/firmware/firmware.hex" "$B/firmware.S"
cp "$HERE/three/uart_hello.S" "$B/uart_hello.S"

# The RTL testbench, once: the core repo's tb_isa.v plus the UART monitor
"$IVERILOG" -g2005 -o "$B/tb_isa.vvp" -I "$CORE_REPO/rtl/pkg" -I "$CORE_REPO/rtl/core" \
  "$CORE_REPO"/rtl/core/*.v "$CORE_REPO"/rtl/cache/*.v \
  "$CORE_REPO/rtl/bus/axi_interconnect.v" "$CORE_REPO/rtl/bus/axi_sram.v" "$CORE_REPO/rtl/bus/axi_periph_bridge.v" \
  "$CORE_REPO"/rtl/periph/*.v "$CORE_REPO/rtl/brv32p_soc.v" "$CORE_REPO/tests/isa/tb_isa.v" "$HERE/three/uart_mon.v" \
  || { echo "run_three.sh: the RTL testbench does not compile" >&2; exit 2; }

REGS=(ra sp gp tp t0 t1 t2 fp s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6)
PLUGIN_ARGS="$PLUGIN"
for r in "${REGS[@]}"; do PLUGIN_ARGS+=",reg=$r"; done

: > "$B/programs.txt"; : > "$B/sha256.txt"
built=()
for ent in "${PROGRAMS[@]}"; do
  name="${ent%%:*}"; kind="${ent##*:}"
  want "$name" || continue
  out="$B/$name"
  # 1. Build once
  case "$kind" in
    directed) src="$CORE_REPO/tests/directed/$name.S"; srclabel="core tests/directed" ;;
    random)   src="$B/$name.S"; srclabel="tests/gen_random.py" ;;
    local)    src="$B/$name.S"; srclabel="tests/three" ;;
  esac
  if [ "$name" = dsp_small ]; then
    CROSS="$CROSS" "$HERE/three/build_dsp_small.sh" "$CORE_REPO" "$out.elf" 2> "$out.build.log" \
      || { echo "BUILD FAIL $name (see $out.build.log)"; exit 2; }
    srclabel="core tests/bench kernels"
  else
    "${CROSS}gcc" -march="$MARCH" -mabi=ilp32 -static -mcmodel=medany -nostdlib -nostartfiles \
      -I "$CORE_REPO/tests/isa/env" -I "$RISCV_TESTS/isa/macros/scalar" -T "$CORE_REPO/tests/isa/env/link.ld" \
      "$src" -o "$out.elf" 2> "$out.build.log" || { echo "BUILD FAIL $name (see $out.build.log)"; exit 2; }
  fi
  [ "$name" = firmware ] && srclabel="core firmware.hex"
  tohost="$("${CROSS}nm" "$out.elf" | awk '$3 == "tohost" { print $1 }')"
  "${CROSS}objdump" -d "$out.elf" > "$out.dis"
  ( cd "$B" && sha256sum "$name.elf" ) >> "$B/sha256.txt"
  spike=1; [[ "$NO_SPIKE" == *" $name "* ]] && spike=0
  trace=1; [[ "$NO_TRACE" == *" $name "* ]] && trace=0
  ignore=""
  # The firmware reads mcycle once, which differs by design
  [ "$name" = firmware ] && ignore="$(tr '\n' ' ' < "$B/firmware.S.ignore")"
  printf 'tohost=%s\nspike=%s\ntrace=%s\nignore=%s\nsrc=%s\n' "$tohost" "$spike" "$trace" "$ignore" "$srclabel" > "$out.meta"
  echo "$name" >> "$B/programs.txt"
  built+=("$name")

  # 2. The RTL: the hex image, the retire trace, the UART bytes
  "${CROSS}objcopy" -O binary "$out.elf" "$out.bin"
  python3 "$CORE_REPO/tests/isa/elf2hex.py" "$out.bin" "$out.hex"
  ( cd "$B" && timeout 1200 "$VVP" -n tb_isa.vvp +hex="$out.hex" +tohost="$tohost" +trace="$out.rtl.trace" \
      +uartlog="$out.rtl.uart" +timeout=1000000 | grep '^RESULT' > "$out.rtl.out" ) || true
  [ -s "$out.rtl.out" ] || echo "RESULT ERROR (simulator)" > "$out.rtl.out"
  [ -f "$out.rtl.uart" ] || : > "$out.rtl.uart"

  # 3. QEMU: first without the trace (the exit status and the UART), then with it
  timeout 60 "$QEMU" -M brv32p -display none -monitor none -serial "file:$out.qemu.uart" -no-reboot \
    -icount shift=${SHIFT[$name]:-3} -kernel "$out.elf" > "$out.qemu.out" 2>&1
  echo $? > "$out.qemu.rc"
  if [ "$trace" = 1 ]; then
    ( ulimit -f 2000000; timeout 120 "$QEMU" -M brv32p -display none -monitor none -serial none -no-reboot \
        -kernel "$out.elf" -plugin "$PLUGIN_ARGS" -d plugin,int -D "$out.qemu.trace" > "$out.qemu.trace.out" 2>&1 )
    echo $? > "$out.qemu.trace.rc"
  fi

  # 4. Spike
  if [ "$spike" = 1 ]; then
    ext=(); [[ "$EXT" == *" $name "* ]] && ext=(--extlib="$XBRVDSP_LIB" --extension=xbrvdsp)
    ( ulimit -f 2000000; timeout 120 "$SPIKE" --isa="$MARCH" "${ext[@]}" -m0x80000000:0x8000 --log-commits \
        "$out.elf" 2> "$out.spike.trace" > /dev/null )
    echo $? > "$out.spike.rc"
  fi
  echo "  ran $name"
done

[ ${#built[@]} -gt 0 ] || { echo "run_three.sh: no such program" >&2; exit 2; }
python3 "$HERE/three_compare.py" "$B" --core "$CORE_REPO" --md "$B/results_q3.md" "${built[@]}"

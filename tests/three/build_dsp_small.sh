#!/usr/bin/env bash
# build_dsp_small.sh <core-repo> <out.elf> - build tests/three/dsp_small.c with the core repo's
# benchmark sources, start-up code and linker script (tests/bench), as its run_bench.sh does.
# The one change: the benchmarks link for 64 KB of SRAM (stack at 0x80010000); the SoC has 32 KB, so
# the two numbers in the linker script that name the top of memory are lowered by 32 KB, by sed.
# dsp.c is compiled with its main renamed (bench_main) and everything is linked with --gc-sections,
# so only the kernels dsp_small.c calls end up in the ELF.
set -euo pipefail
CORE="$1"; OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH="$CORE/tests/bench"
CROSS="${CROSS:-riscv64-unknown-elf-}"
MARCH=rv32imc_zicsr
MARCH_ZK="${MARCH}_zbkb_zbkc_zbkx_zknh_zkne_zknd"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 "$BENCH/gen_data.py" > "$T/bench_data.h"
sed -e 's/0x80010000/0x80008000/' -e 's/0x8000F000/0x80007000/' "$BENCH/link.ld" > "$T/link.ld"
CFLAGS=(-O2 -falign-loops=4 -mabi=ilp32 -mcmodel=medany -ffreestanding -ffunction-sections -fdata-sections
        -I "$T" -I "$BENCH")
"${CROSS}gcc" "${CFLAGS[@]}" -march="$MARCH_ZK" -c "$BENCH/mlkem_x.c" -o "$T/mlkem_x.o"
"${CROSS}gcc" "${CFLAGS[@]}" -march="$MARCH" -Dmain=bench_main -c "$BENCH/dsp.c" -o "$T/dsp.o"
"${CROSS}gcc" "${CFLAGS[@]}" -march="$MARCH" -c "$BENCH/mlkem.c" -o "$T/mlkem.o"
"${CROSS}gcc" "${CFLAGS[@]}" -march="$MARCH" -c "$HERE/dsp_small.c" -o "$T/main.o"
"${CROSS}gcc" "${CFLAGS[@]}" -march="$MARCH" -c "$BENCH/crt.S" -o "$T/crt.o"
"${CROSS}gcc" -march="$MARCH" -mabi=ilp32 -static -nostdlib -nostartfiles -Wl,--gc-sections -T "$T/link.ld" \
  "$T/crt.o" "$T/main.o" "$T/dsp.o" "$T/mlkem.o" "$T/mlkem_x.o" -o "$OUT"

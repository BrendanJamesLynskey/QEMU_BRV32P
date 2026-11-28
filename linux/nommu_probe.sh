#!/usr/bin/env bash
# nommu_probe.sh — build a no-MMU rv32 kernel with the toolchain linux/build.sh made, and boot it on
# -M brv32p-linux with the same OpenSBI, DT and initramfs. Only the kernel is built, so userspace is the
# ELF initramfs, which a no-MMU kernel cannot run: the probe passes if the kernel reaches "Run /sbin/init".
# Usage: linux/nommu_probe.sh     Env: JOBS (default 2)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
BRO="$ROOT/.cache/br-out"; SRC="$ROOT/.cache/nommu-src/linux-7.1.13"; O="$ROOT/.cache/nommu-out"
[ -d "$SRC" ] || { mkdir -p "$ROOT/.cache/nommu-src"; tar -xJf "$ROOT/.cache/dl/linux/linux-7.1.13.tar.xz" -C "$ROOT/.cache/nommu-src"; }
export ARCH=riscv CROSS_COMPILE="$BRO/host/bin/riscv32-buildroot-linux-musl-" PATH="$BRO/host/bin:$PATH"
mkdir -p "$O"
make -C "$SRC" O="$O" rv32_defconfig
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$O" "$O/.config" "$HERE/kernel.fragment" "$HERE/nommu.fragment" > /dev/null
make -C "$SRC" O="$O" olddefconfig
make -C "$SRC" O="$O" -j"${JOBS:-2}" Image
cp "$O/arch/riscv/boot/Image" "$HERE/out/Image.nommu"
grep -E "^# CONFIG_MMU is not set|^CONFIG_ARCH_RV32I=y" "$O/.config"
QEMU="${QEMU:-$ROOT/build/qemu/qemu-system-riscv32}"
timeout 120 "$QEMU" -M brv32p-linux -display none -monitor none -serial stdio -bios "$HERE/out/fw_dynamic.bin" \
  -kernel "$HERE/out/Image.nommu" -initrd "$HERE/out/rootfs.cpio" -dtb "$HERE/out/brv32p-linux.dtb" < /dev/null > "$HERE/out/nommu.log" 2>&1 || true
grep -a "Linux version\|Run /sbin/init\|Kernel panic\|Failed\|nommu\|MMU" "$HERE/out/nommu.log" | head

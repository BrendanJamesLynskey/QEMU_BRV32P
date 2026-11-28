#!/usr/bin/env bash
# build.sh — build the software for -M brv32p-linux with Buildroot: a soft-float RV32IMAC musl toolchain, the
# Linux kernel, OpenSBI (generic platform plus the BRV32P UART driver, linux/patches/opensbi) and a BusyBox
# initramfs. Nothing from Buildroot, Linux, OpenSBI or BusyBox is committed: it is fetched at the pinned versions.
#
# Usage: linux/build.sh
# Env:   JOBS   parallel jobs (default 2)
#        OUT    where the images are put (default linux/out)
# Result: $OUT/Image  $OUT/fw_dynamic.bin  $OUT/rootfs.cpio  $OUT/brv32p-linux.dtb  $OUT/versions.txt
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BR_VERSION=2026.08.2
BR_SHA256=8256118146429958ebb9695e7649233875efb5a9568cf7b192017200f7c5e9d2
JOBS="${JOBS:-2}"
OUT="${OUT:-$HERE/out}"
DL="$ROOT/.cache/dl"
BR="$ROOT/.cache/buildroot-$BR_VERSION"
BRO="$ROOT/.cache/br-out"

mkdir -p "$DL" "$OUT"
if [ ! -d "$BR" ]; then
  [ -f "$DL/buildroot-$BR_VERSION.tar.gz" ] ||
    curl -fsSL -o "$DL/buildroot-$BR_VERSION.tar.gz" "https://buildroot.org/downloads/buildroot-$BR_VERSION.tar.gz"
  echo "$BR_SHA256  $DL/buildroot-$BR_VERSION.tar.gz" | sha256sum -c -
  tar -xzf "$DL/buildroot-$BR_VERSION.tar.gz" -C "$ROOT/.cache"
fi

# The defconfig has @LINUX@ and @ROOT@ for the absolute paths
sed -e "s#@LINUX@#$HERE#g" -e "s#@ROOT@#$ROOT#g" "$HERE/brv32p_linux_defconfig" > "$ROOT/.cache/brv32p_linux_defconfig"

mkdir -p "$BRO"
make -C "$BR" O="$BRO" BR2_DEFCONFIG="$ROOT/.cache/brv32p_linux_defconfig" defconfig
make -C "$BRO" -j"$JOBS"

cp "$BRO/images/Image" "$BRO/images/fw_dynamic.bin" "$BRO/images/rootfs.cpio" "$OUT/"
cp "$BRO/images/brv32p-linux.dtb" "$OUT/"
{
  echo "buildroot $BR_VERSION"
  grep -E '^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE|^BR2_TARGET_OPENSBI_CUSTOM_VERSION_VALUE' "$ROOT/.cache/brv32p_linux_defconfig"
  grep -E '^BR2_PACKAGE_BUSYBOX_VERSION|^BR2_TOOLCHAIN_BUILDROOT_MUSL' "$BRO/.config" || true
  ls -l "$OUT"
} > "$OUT/versions.txt"
echo "built: $OUT"

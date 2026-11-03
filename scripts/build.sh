#!/usr/bin/env bash
# build.sh — fetch the pinned QEMU release, apply patches/*.patch and build
# qemu-system-riscv32.
#
# Usage: scripts/build.sh
# Env:   JOBS   parallel jobs (default 2: the build shares a small machine)
#        SRC    where the QEMU sources are fetched (default .cache/qemu-src)
#        BUILD  the build tree (default build/qemu)
# The release tag is read from QEMU_VERSION, the one place it is pinned.
# Result: $BUILD/qemu-system-riscv32
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="$(tr -d '[:space:]' < "$ROOT/QEMU_VERSION")"
SRC="${SRC:-$ROOT/.cache/qemu-src}"
BUILD="${BUILD:-$ROOT/build/qemu}"
JOBS="${JOBS:-2}"

# Fetch the tag shallowly (only if the sources are not already at it)
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone -q --depth 1 --branch "$TAG" https://gitlab.com/qemu-project/qemu.git "$SRC"
fi
cd "$SRC"
base="$(git rev-parse "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
[ -n "$base" ] || { echo "build.sh: $SRC is not a checkout of $TAG" >&2; exit 1; }

# Apply the patch series on the tag. git am needs an identity, but only to
# record the commits, so give it a throwaway one.
git reset -q --hard "$base"
git clean -q -fd
git -c user.name=brv32p-build -c user.email=build@invalid \
    am --quiet --3way "$ROOT"/patches/*.patch

# A minimal build: one target, no GUI, no docs, no tools
mkdir -p "$BUILD"
cd "$BUILD"
"$SRC/configure" \
  --target-list=riscv32-softmmu \
  --disable-docs --disable-tools --disable-guest-agent \
  --disable-gtk --disable-sdl --disable-vnc --disable-opengl --disable-curses \
  --disable-vhost-net --disable-vhost-user --disable-vhost-kernel \
  --disable-vhost-user-blk-server --disable-vhost-vdpa --disable-vhost-crypto \
  --disable-libssh --disable-rbd --disable-libnfs \
  --disable-vde --disable-brlapi --disable-curl --disable-nettle \
  --disable-gnutls --disable-gcrypt --disable-capstone \
  --disable-replication \
  --disable-seccomp --disable-slirp --disable-usb-redir --disable-smartcard \
  --disable-spice --disable-libusb --disable-selinux --disable-numa \
  --disable-pa --disable-alsa --disable-jack --disable-oss --disable-pipewire \
  --disable-sndio --disable-dbus-display --disable-rust \
  --disable-werror
make -j"$JOBS" qemu-system-riscv32
echo "built: $BUILD/qemu-system-riscv32"

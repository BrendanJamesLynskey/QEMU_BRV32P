# Linux stage 1: boot Linux on a Linux-capable variant of the BRV32P model

Adds `-M brv32p-linux` (patch 0008) and the software to boot OpenSBI and Linux to a BusyBox shell on it, and
records in [`docs/linux.md`](docs/linux.md) what the RTL must gain for stages 2 to 5. `-M brv32p`, its CPU and its
tests are unchanged (the four machine tests pass on the rebuilt QEMU; CI runs the rest).

## What is added

- **Machine and CPU** (patch 0008): `brv32p-linux`, a separate machine type with a `brv32p-linux` CPU: RV32IMAC,
  M, S and U modes, Sv32, Zicntr and the 64-bit counters, the custom extensions and the misaligned trap kept, no
  PMP. 128 MiB of fully decoded RAM at 0x8000_0000, the 32 KB boot SRAM at 0 holding the reset vector, the GPIO,
  UART and timer where the RTL has them, an ACLINT at 0x2001_0000, a power-off finisher at 0x2002_0000.
- **Software** ([`linux/build.sh`](linux/build.sh)): Buildroot 2026.08.2 builds a soft-float rv32 musl toolchain,
  Linux 7.1.13, OpenSBI 1.8.1 with a 40-line driver for the BRV32P UART, and a BusyBox initramfs. Nothing is
  committed from those projects.
- **Test** ([`linux/boot_test.sh`](linux/boot_test.sh)): boots headless and checks the OpenSBI banner, the kernel
  version line, a shell, `uname -m` (`riscv32`), `/proc/cpuinfo` (`rv32imac`, `sv32`) and a clean power-off (QEMU exit 0).
- **No-MMU probe** ([`linux/nommu_probe.sh`](linux/nommu_probe.sh)).
- **CI**: a `linux-boot` job (needs `test`), caching the images on the hash of the build script, configs, DT and
  patch. The existing jobs are unchanged.

## Results

See [`docs/linux.md`](docs/linux.md) for the tables.

- Boots to a shell on 128 MiB; the minimum RAM that booted is 64 MiB. Kernel `Image` 25.9 MB, OpenSBI 270 KB,
  initramfs 1.7 MB. About 0.28 G instructions from kernel entry to init (mostly console busy-waits).
- Console: option (a), the SBI console over the existing UART, needs no RTL. Found: the UART keeps one received
  byte, so a burst of input is lost; the test types one character at a time. An RX FIFO is on the RTL list.
- Timer: a standard ACLINT. No PLIC is needed in stage 1; the owner's PLIC is reusable behind a bridge, the MMU
  needs adapting, and `RISCV_SoC` is not usable as a base (its integration tests do not run against the current core).
- PMP is not needed: OpenSBI booted with none.
- No-MMU: current mainline builds it for rv32 and it boots to the init process in S-mode (6.9 MB Image). It saves
  Sv32, not S-mode; an M-mode-only kernel would need a kernel UART driver. Pitfall: a no-MMU kernel defaults to
  M-mode and traps under OpenSBI.

## Not done

- No-MMU userspace (flat or FDPIC binaries) was not built, so the no-MMU kernel stops at the init exec.
- The kernel is not minimal: most of `rv32_defconfig`'s drivers remain.
- The pass or fail of the `linux-boot` CI job is stated in the PR conversation after its run.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

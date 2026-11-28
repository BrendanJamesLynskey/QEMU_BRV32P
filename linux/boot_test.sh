#!/usr/bin/env bash
# boot_test.sh — boot OpenSBI and Linux headless on -M brv32p-linux, check the banner, the kernel version line,
# the shell prompt and the output of two commands, and power off through the SBI reset.
#
# Usage: linux/boot_test.sh
# Env:   QEMU     qemu-system-riscv32 (default build/qemu/qemu-system-riscv32)
#        OUT      the images from linux/build.sh (default linux/out)
#        TIMEOUT  seconds for the whole run (default 300)
#        MEM      RAM size for -m (default 128M)
#        ICOUNT=1 run with -icount shift=0: one instruction is 1 ns of virtual time, so the kernel's timestamps
#                 read as instructions (the timestamp of "Run /sbin/init" is the instructions from kernel entry)
# The console is the BRV32P UART (-serial stdio) read by OpenSBI's SBI console; the log is $OUT/boot.log.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
QEMU="${QEMU:-$ROOT/build/qemu/qemu-system-riscv32}"
OUT="${OUT:-$HERE/out}"
TIMEOUT="${TIMEOUT:-300}"
MEM="${MEM:-128M}"
LOG="$OUT/boot.log"
IN="$OUT/boot.in"
PLUGIN=()
[ "${ICOUNT:-0}" = 1 ] && PLUGIN=(-icount shift=0,sleep=off)

rm -f "$LOG" "$IN"; mkfifo "$IN"
"$QEMU" -M brv32p-linux -m "$MEM" -display none -monitor none -serial stdio \
  -bios "$OUT/fw_dynamic.bin" -kernel "$OUT/Image" -initrd "$OUT/rootfs.cpio" -dtb "$OUT/brv32p-linux.dtb" \
  "${PLUGIN[@]}" < "$IN" > "$LOG" 2>&1 &
QPID=$!
exec 3> "$IN"
( sleep "$TIMEOUT"; kill "$QPID" 2>/dev/null ) &
WPID=$!

# The BRV32P UART holds one received byte and the SBI console is polled, so a burst of input loses all but its
# last byte (an overrun). The test therefore types one character at a time, as a person would.
send() {       # send <line>
  local line="$1" i
  for ((i = 0; i < ${#line}; i++)); do printf '%s' "${line:i:1}" >&3; sleep "${CHAR_DELAY:-0.05}"; done
  printf '\n' >&3
}
wait_for() {   # wait_for <text> <seconds>
  local i
  for ((i = 0; i < $2 * 10; i++)); do
    grep -qF -- "$1" "$LOG" 2>/dev/null && return 0
    kill -0 "$QPID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
fail=0
check() {      # check <description> <text>
  if grep -qF -- "$2" "$LOG"; then echo "ok:   $1"; else echo "FAIL: $1 (no '$2')"; fail=1; fi
}

# The shell is up when it answers; the markers are computed ($((..))) so the typed echo does not match them
wait_for "Run /sbin/init" "$TIMEOUT" || echo "kernel did not reach init"
for ((i = 0; i < 60; i++)); do
  send "echo READY\$((1+0))"
  wait_for "READY1" 3 && break
done
send "uname -m; echo END\$((0+1))";   wait_for "END1" 60
send "cat /proc/cpuinfo; echo END\$((0+2))"; wait_for "END2" 60
send "head -3 /proc/meminfo; cat /proc/uptime; echo END\$((0+3))"; wait_for "END3" 60
send "poweroff"

# Clean power-off: QEMU exits by itself with status 0
for ((i = 0; i < 300; i++)); do kill -0 "$QPID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$QPID" 2>/dev/null; then echo "FAIL: no power-off"; kill "$QPID"; fail=1; rc=1; else wait "$QPID"; rc=$?; fi
kill "$WPID" 2>/dev/null; exec 3>&-
[ "${rc:-0}" = 0 ] && echo "ok:   QEMU exited with status 0" || { echo "FAIL: QEMU status $rc"; fail=1; }

check "OpenSBI banner"            "OpenSBI v"
check "OpenSBI sees the machine"  "Platform Name"
check "kernel version line"       "Linux version "
check "userspace shell answers"    "READY1"
check "uname -m"                  "riscv32"
check "cpuinfo isa"               "rv32imac"
check "cpuinfo mmu"               "sv32"
cat "$LOG" | tail -40
exit $fail

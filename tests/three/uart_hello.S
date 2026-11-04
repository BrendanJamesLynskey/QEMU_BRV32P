/*
 * uart_hello.S - prints a line on the UART and ends through tohost.
 *
 * Step Q3's test of the UART output: the QEMU model and the RTL must send the
 * same bytes. Spike has no UART, so this runs on those two only. It sets the
 * divider (8: nine clocks a bit), waits for the transmitter to be idle before
 * each byte (a byte written while it is busy is dropped), and waits for the last
 * frame to finish before it stores to tohost.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define UART_BASE 0x20000100

RVTEST_RV32U
RVTEST_CODE_BEGIN

  li      s0, UART_BASE
  li      t0, 8
  sw      t0, 12(s0)              # CLKDIV
  li      TESTNUM, 2
  la      s1, msg
1:
  lbu     a0, 0(s1)
  beqz    a0, 3f
2:
  lw      t1, 8(s0)               # STATUS, bit 0 = tx_busy
  andi    t1, t1, 1
  bnez    t1, 2b
  sw      a0, 0(s0)
  addi    s1, s1, 1
  j       1b
3:
  lw      t1, 8(s0)               # the last frame must finish
  andi    t1, t1, 1
  bnez    t1, 3b
  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

msg:
  .string "BRV32P: one binary, three platforms\n"

RVTEST_DATA_END

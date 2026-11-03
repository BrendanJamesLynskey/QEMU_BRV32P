/*
 * uart.S — the BRV32P UART: reset value, transmit with the busy flag, the
 * divider, and receive with the valid flag, its interrupt (machine external
 * interrupt) and the overrun flag.
 *
 * Written for the machine model. The host feeds bytes on the serial line
 * (tests/run_machine.py): the program sends '>' when it is ready for the next
 * byte(s), and "ok" when it has checked them all, then passes through tohost.
 * It writes "ut>>>ok" in all.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define UART_BASE   0x20000100
#define U_TX        0
#define U_RX        4
#define U_STATUS    8
#define U_DIV       12

#define ST_BUSY     1
#define ST_VALID    2
#define ST_OVERRUN  4

#define MIE_MEIE    (1 << 11)

/* Send a character and wait for the transmitter to be idle again */
#define PUTC(c)                                                         \
  li      t1, c;                                                        \
  sw      t1, U_TX(s0);                                                 \
9:lw      t1, U_STATUS(s0);                                             \
  andi    t1, t1, ST_BUSY;                                              \
  bnez    t1, 9b
#define MSTATUS_MIE (1 << 3)

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  li      s0, UART_BASE
  li      s2, 0                   # interrupts taken
  li      s3, 0                   # interrupts with the wrong mcause

  # 2: reset values: divider 867, nothing busy or received
  li      TESTNUM, 2
  lw      t1, U_DIV(s0)
  li      t2, 867
  bne     t1, t2, fail
  lw      t1, U_STATUS(s0)
  bnez    t1, fail
  lw      t1, U_TX(s0)            # TX reads as 0
  bnez    t1, fail

  # 3: the divider is 16 bits wide; a fast divider for the rest
  li      TESTNUM, 3
  li      t1, 0xffff1234
  sw      t1, U_DIV(s0)
  lw      t1, U_DIV(s0)
  li      t2, 0x1234
  bne     t1, t2, fail
  li      t1, 2
  sw      t1, U_DIV(s0)           # a frame is 10 * 3 cycles

  # 4: a write starts a frame: busy is set, then clears; a write while busy
  # is dropped
  li      TESTNUM, 4
  li      t1, 'u'
  sw      t1, U_TX(s0)
  lw      t1, U_STATUS(s0)
  andi    t1, t1, ST_BUSY
  beqz    t1, fail
  li      t1, 'X'
  sw      t1, U_TX(s0)            # dropped: 'X' never appears
  li      t3, 100000
1:lw      t1, U_STATUS(s0)
  andi    t1, t1, ST_BUSY
  beqz    t1, 2f
  addi    t3, t3, -1
  bnez    t3, 1b
  j       fail
2:PUTC('t')

  # 5: receive by polling: the host sends 'a' when it sees '>'; the valid
  # flag is set, the read clears it
  li      TESTNUM, 5
  PUTC('>')
  li      t3, 50000000
1:lw      t1, U_STATUS(s0)
  andi    t1, t1, ST_VALID
  bnez    t1, 2f
  addi    t3, t3, -1
  bnez    t3, 1b
  j       fail
2:lw      t1, U_RX(s0)
  li      t2, 'a'
  bne     t1, t2, fail
  lw      t1, U_STATUS(s0)
  andi    t1, t1, ST_VALID
  bnez    t1, fail                # cleared by the read

  # 6: receive by interrupt: 'b' raises the external interrupt, which stays
  # until the byte is read
  li      TESTNUM, 6
  li      t1, MIE_MEIE
  csrw    mie, t1
  csrsi   mstatus, MSTATUS_MIE
  PUTC('>')
  li      t3, 50000000
1:bnez    s2, 2f
  addi    t3, t3, -1
  bnez    t3, 1b
  j       fail
2:csrci   mstatus, MSTATUS_MIE
  bnez    s3, fail                # mcause was 0x8000000b
  li      t2, 'b'
  bne     s6, t2, fail            # the handler read 'b'
  li      t2, 1
  bne     s2, t2, fail            # one interrupt, not a storm

  # 7: overrun: "cde" arrive back to back while nothing is read; the sticky
  # overrun flag is set and the last byte is the one kept
  li      TESTNUM, 7
  PUTC('>')
  li      t3, 50000000
1:lw      t1, U_STATUS(s0)
  andi    t1, t1, ST_OVERRUN
  bnez    t1, 2f
  addi    t3, t3, -1
  bnez    t3, 1b
  j       fail
2:li      t3, 50000000            # read until the last byte, 'e', is there
3:lw      t1, U_RX(s0)
  li      t2, 'e'
  beq     t1, t2, 4f
  addi    t3, t3, -1
  bnez    t3, 3b
  j       fail
4:lw      t1, U_STATUS(s0)
  andi    t1, t1, ST_OVERRUN
  beqz    t1, fail                # sticky: a read does not clear it

  PUTC('o')
  PUTC('k')

  TEST_PASSFAIL

  .align  2
handler:
  csrr    t5, mcause
  li      t6, 0x8000000b
  beq     t5, t6, 2f
  addi    s3, s3, 1
2:li      t5, UART_BASE
  lw      s6, U_RX(t5)            # the read clears the interrupt
  addi    s2, s2, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END

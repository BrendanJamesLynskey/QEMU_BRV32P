/*
 * gpio.S — the BRV32P GPIO: reset values, the direction register, the
 * rising-edge interrupt with its write-1-to-clear status, and the machine
 * external interrupt.
 *
 * Written for the machine model. The host drives the pins through the QOM
 * property gpio-in and reads them back from gpio-out (tests/run_machine.py).
 * Handshake on the UART: '>' ready for the pin changes, 'a' first interrupt
 * seen, 'b' second interrupt seen and the outputs set; then the program waits
 * for any byte from the host (which has read the pins) and ends.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define GPIO_BASE   0x20000000
#define UART_BASE   0x20000100
#define G_OUT       0x00
#define G_IN        0x04
#define G_DIR       0x08
#define G_IRQ_EN    0x0c
#define G_IRQ_STAT  0x10
#define U_TX        0
#define U_STATUS    8
#define U_DIV       12

#define MIE_MEIE    (1 << 11)
#define MSTATUS_MIE (1 << 3)

#define PUTC(c)                                                         \
  li      t1, c;                                                        \
  sw      t1, U_TX(s1);                                                 \
9:lw      t1, U_STATUS(s1);                                             \
  andi    t1, t1, 1;                                                    \
  bnez    t1, 9b

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  li      s0, GPIO_BASE
  li      s1, UART_BASE
  li      s2, 0                   # interrupts taken
  li      s3, 0                   # interrupts with a wrong mcause or status
  li      t1, 2
  sw      t1, U_DIV(s1)

  # 2: reset values
  li      TESTNUM, 2
  lw      t1, G_OUT(s0)
  bnez    t1, fail
  lw      t1, G_DIR(s0)
  bnez    t1, fail
  lw      t1, G_IRQ_EN(s0)
  bnez    t1, fail
  lw      t1, G_IRQ_STAT(s0)
  bnez    t1, fail

  # 3: the registers read back, DATA_IN is read-only, the unused offsets
  # read as 0, and the GPIO repeats every 32 bytes and at 0x300 to 0xfff
  li      TESTNUM, 3
  li      t1, 0x5a5a1234
  sw      t1, G_OUT(s0)
  lw      t2, G_OUT(s0)
  bne     t1, t2, fail
  sw      zero, G_OUT(s0)
  li      t1, 0xdeadbeef
  sw      t1, G_IN(s0)            # ignored
  lw      t2, G_IN(s0)
  beq     t1, t2, fail
  lw      t2, 0x14(s0)
  bnez    t2, fail
  li      t1, 0x0f0f0f0f
  sw      t1, 0x28(s0)            # offset 0x28 = DIR again
  lw      t2, G_DIR(s0)
  bne     t1, t2, fail
  sw      zero, G_DIR(s0)
  li      t1, 0x55
  sw      t1, 0x700(s0)           # addr[11:8] = 7 selects the GPIO as well
  lw      t2, G_OUT(s0)
  bne     t1, t2, fail
  sw      zero, G_OUT(s0)

  # 4: a byte store writes a whole word, with the byte repeated in all four
  # lanes (the bridge ignores the byte strobes), a byte load takes its lane
  li      TESTNUM, 4
  li      t1, 0x7b
  sb      t1, G_OUT(s0)
  lw      t2, G_OUT(s0)
  li      t3, 0x7b7b7b7b
  bne     t2, t3, fail
  lbu     t2, G_OUT+2(s0)
  li      t3, 0x7b
  bne     t2, t3, fail
  sw      zero, G_OUT(s0)

  # 5: the external interrupt on a rising edge of pin 0
  li      TESTNUM, 5
  li      t1, 1
  sw      t1, G_IRQ_EN(s0)
  li      t1, MIE_MEIE
  csrw    mie, t1
  csrsi   mstatus, MSTATUS_MIE
  PUTC('>')
  li      t3, 0x20000000
1:li      t4, 1
  bge     s2, t4, 2f
  addi    t3, t3, -1
  bnez    t3, 1b
  j       fail
2:PUTC('a')
  li      t3, 0x20000000
1:li      t4, 2
  bge     s2, t4, 2f
  addi    t3, t3, -1
  bnez    t3, 1b
  j       fail
2:csrci   mstatus, MSTATUS_MIE
  bnez    s3, fail

  # 6: the outputs are data_out & dir
  li      TESTNUM, 6
  li      t1, 0xff
  sw      t1, G_OUT(s0)           # dir is still 0: nothing is driven
  li      t1, 0x3c
  sw      t1, G_DIR(s0)
  PUTC('b')
  # wait for the host to read the pins and send a byte, so that the run does
  # not end before it has
  li      t3, 0x20000000
1:lw      t1, U_STATUS(s1)
  andi    t1, t1, 2
  bnez    t1, 2f
  addi    t3, t3, -1
  bnez    t3, 1b
  j       fail
2:
  TEST_PASSFAIL

  .align  2
handler:
  csrr    t5, mcause
  li      t6, 0x8000000b
  beq     t5, t6, 2f
  addi    s3, s3, 1
2:li      t5, GPIO_BASE
  lw      t6, G_IRQ_STAT(t5)
  li      a0, 1
  beq     t6, a0, 3f
  addi    s3, s3, 1               # only pin 0 had its interrupt enabled
3:sw      t6, G_IRQ_STAT(t5)      # write 1 to clear
  addi    s2, s2, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END

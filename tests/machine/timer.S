/*
 * timer.S — the BRV32P timer, its match flag and the machine timer interrupt.
 *
 * Written for the machine model (it is not in the core repo). It checks the
 * reset values, the tick arithmetic that rtl/periph/timer.v defines (with a
 * prescaler of 3 a tick is every 4 cycles, and with compare N the flag is set
 * on tick N + 1), the level interrupt (MTIP follows the match flag), the
 * mcause of the interrupt, auto-reload, and a one-shot run that stops at
 * compare.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define TIMER_BASE  0x20000200
#define T_CTRL      0
#define T_PRESCALER 4
#define T_COMPARE   8
#define T_COUNT     12
#define T_STATUS    16

#define MIE_MTIE    (1 << 7)
#define MSTATUS_MIE (1 << 3)

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  li      s0, TIMER_BASE
  li      s2, 0                   # interrupts taken
  li      s3, 0                   # interrupts with the wrong mcause
  li      s4, 0                   # interrupts with the match flag clear

  # 2: reset values
  li      TESTNUM, 2
  lw      t1, T_CTRL(s0)
  bnez    t1, fail
  lw      t1, T_PRESCALER(s0)
  bnez    t1, fail
  lw      t1, T_COMPARE(s0)
  li      t2, -1
  bne     t1, t2, fail
  lw      t1, T_COUNT(s0)
  bnez    t1, fail
  lw      t1, T_STATUS(s0)
  bnez    t1, fail

  # 3: registers read back; only bits 1:0 of CTRL exist
  li      TESTNUM, 3
  li      t1, 0xfffffffc
  sw      t1, T_CTRL(s0)
  lw      t1, T_CTRL(s0)
  bnez    t1, fail
  li      t1, 0x12345678
  sw      t1, T_PRESCALER(s0)
  lw      t2, T_PRESCALER(s0)
  bne     t1, t2, fail
  sw      zero, T_PRESCALER(s0)
  sw      t1, T_COUNT(s0)
  lw      t2, T_COUNT(s0)
  bne     t1, t2, fail
  sw      zero, T_COUNT(s0)

  # 4: a stopped timer does not count
  li      TESTNUM, 4
  li      t1, 100
  sw      t1, T_COMPARE(s0)
  li      t3, 2000
1:addi    t3, t3, -1
  bnez    t3, 1b
  lw      t1, T_COUNT(s0)
  bnez    t1, fail
  lw      t1, T_STATUS(s0)
  bnez    t1, fail

  # 5: one-shot (auto-reload off): count stops at compare and the flag is set
  li      TESTNUM, 5
  li      t1, 2
  sw      t1, T_COMPARE(s0)       # compare 2: flag on tick 3
  li      t1, 1
  sw      t1, T_CTRL(s0)          # enabled, prescaler 0: a tick per cycle
  li      t3, 100000
1:lw      t1, T_STATUS(s0)
  bnez    t1, 2f
  addi    t3, t3, -1
  bnez    t3, 1b
  j       fail                    # never set
2:lw      t1, T_COUNT(s0)
  li      t2, 2
  bne     t1, t2, fail            # stopped at compare
  # still set and still stopped a while later
  li      t3, 1000
1:addi    t3, t3, -1
  bnez    t3, 1b
  lw      t1, T_COUNT(s0)
  li      t2, 2
  bne     t1, t2, fail
  lw      t1, T_STATUS(s0)
  li      t2, 1
  bne     t1, t2, fail
  # writing 1 to the flag clears it (the counter is still at compare, so
  # the next tick sets it again)
  sw      zero, T_CTRL(s0)
  li      t1, 1
  sw      t1, T_STATUS(s0)
  lw      t1, T_STATUS(s0)
  bnez    t1, fail

  # 6: the timer interrupt: prescaler 3, compare 20, auto-reload, 5 interrupts
  li      TESTNUM, 6
  sw      zero, T_COUNT(s0)
  li      t1, 3
  sw      t1, T_PRESCALER(s0)
  li      t1, 20
  sw      t1, T_COMPARE(s0)
  li      t1, MIE_MTIE
  csrw    mie, t1
  csrsi   mstatus, MSTATUS_MIE
  li      t1, 3
  sw      t1, T_CTRL(s0)          # enabled, auto-reload
  li      t3, 5
  li      s5, 3000000
1:blt   s2, t3, 3f
  j       4f
3:addi    s5, s5, -1
  bnez    s5, 1b
  j       fail                    # the interrupts never came
4:
  csrci   mstatus, MSTATUS_MIE
  sw      zero, T_CTRL(s0)
  bnez    s3, fail                # every mcause was 0x80000007
  bnez    s4, fail                # the flag was set in every handler

  TEST_PASSFAIL

  .align  2
handler:
  csrr    t5, mcause
  li      t6, 0x80000007
  beq     t5, t6, 2f
  addi    s3, s3, 1
2:li      t5, TIMER_BASE
  lw      t6, T_STATUS(t5)
  bnez    t6, 3f
  addi    s4, s4, 1
3:li      t6, 1
  sw      t6, T_STATUS(t5)        # clear the match flag, which drops MTIP
  lw      t6, T_COUNT(t5)
  addi    s2, s2, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END

# Q0: the design note for the QEMU model of the BRV32P SoC

Adds `docs/design.md` (and the repo scaffolding on `main`), taken from the RTL with file and line references.

It covers:

* the memory map: the 32 KB SRAM and the peripheral window (`addr[31:28] == 2`), with each device's offset;
* every register of the UART, GPIO and timer: offset, width, access, side effects, reset value, IRQ condition;
* the interrupt wiring (checked in the RTL): no PLIC; `gpio_irq | uart_irq` into MEIP, the timer into MTIP;
* the reset PC and the boot flow;
* how tests end, the choice for QEMU and the alternatives considered;
* what Q1 models and leaves out, and the outline of Q2 and Q3.

## For the reviewer

* **The proposed HTIF reuse does not work as it stands on RV32.** QEMU's HTIF acts on a `tohost` write only when
  the upper word is written, and the core's test env stores the lower word only. The note proposes keeping the
  HTIF exit convention but acting on the first 32-bit store to the ELF's `tohost` symbol.
* **A finding in the RTL, not changed here:** the D-cache has no bypass for peripheral addresses, so a second
  read of a peripheral register is served from the cache (seen in simulation: two reads of the timer count return
  the same value), and a line fill reads the neighbouring registers, with their side effects (a fill of the UART
  line clears `rx_valid`). The model is uncached, so it does not reproduce this.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

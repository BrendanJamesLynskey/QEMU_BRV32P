`timescale 1ns / 1ps
// ============================================================================
// uart_mon.v - decodes what the SoC sends on its UART TX pin, for step Q3
// ============================================================================
// A second top-level module compiled beside the core repo's tests/isa/tb_isa.v
// (which is not changed): it reads tb_isa's uart_tx pin and the UART's clk_div
// by hierarchical name, decodes the 8N1 frames and writes each byte to the file
// given by +uartlog=<file>. Without the plusarg it does nothing.
// ============================================================================
module uart_mon;

  integer          fd, i, period;
  reg [7:0]        b;
  reg [8*512-1:0]  path;

  initial begin
    fd = 0;
    if ($value$plusargs("uartlog=%s", path)) fd = $fopen(path, "w");
  end

  // Falling edge = start bit. Sample each bit in the middle: 1.5 bit times
  // after the edge for bit 0, then one bit time apart. The clock is 10 ns.
  always @(negedge tb_isa.uart_tx) if (fd != 0 && tb_isa.rst_n) begin
    period = (tb_isa.dut.u_uart.clk_div + 1) * 10;
    #(period + period / 2);
    for (i = 0; i < 8; i = i + 1) begin
      b[i] = tb_isa.uart_tx;
      #(period);
    end
    $fwrite(fd, "%c", b);
    $fflush(fd);
  end

endmodule

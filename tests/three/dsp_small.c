/*
 * dsp_small.c - the "real program" of step Q3: the core repo's DSP and ML-KEM
 * kernels, run on all three platforms.
 *
 * The kernels are the core repo's own (tests/bench/dsp.c, mlkem.c, mlkem_x.c),
 * compiled unchanged; only main is replaced (dsp.c's is built as bench_main and
 * dropped by --gc-sections), because the whole benchmark is 38 KB of code and
 * the SoC has 32 KB of SRAM. This main runs, and checks against the values
 * gen_data.py computed:
 *   - the FIR in plain C, with mac, dmac, the address generators, and with the
 *     hardware loop (lp.setup, dmac.lp);
 *   - the energy kernel in plain C, with dmac and with the hardware loop;
 *   - the ML-KEM NTT and inverse NTT as pq-crystals' reference has them, and
 *     with the mod-q unit (mqmul2, ctadd2, ctsub2, gsmul2).
 * Returns 0 on a pass, else the number of the first failing check (crt.S turns
 * that into the value stored to tohost).
 */
#include <stdint.h>
#include "bench_data.h"

void fir_q15(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps);
void fir_q15_mac(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps);
void fir_q15_agu(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps);
void fir_q15_dmac(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps);
void fir_q15_lp(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps);
int64_t energy_q15(const int16_t *x, int n);
int64_t energy_q15_dmac(const int16_t *x, int n);
int64_t energy_q15_lp(const int16_t *x, int n);
void mlkem_ntt(int16_t *r);
void mlkem_invntt(int16_t *r);
void mlkem_ntt_mq(uint16_t *r);
void mlkem_ntt_ct(uint16_t *r);
void mlkem_invntt_x(uint16_t *r);

static int16_t fir_y[FIR_OUTS];
static uint16_t pa[256] __attribute__((aligned(4)));

static int fir_ok(void)
{
  int ok = 1;
  for (int n = 0; n < FIR_OUTS; n++) {
    ok &= fir_y[n] == fir_expect[n];
    fir_y[n] = 0;                     /* the next kernel must write its own output */
  }
  return ok;
}

/* As dsp.c's poly_eq: the reference leaves coefficients unreduced and signed */
static int poly_ok(const uint16_t *b, int reduce)
{
  int ok = 1;
  for (int i = 0; i < 256; i++) {
    int v = reduce ? ((int16_t)pa[i] % MLKEM_Q + MLKEM_Q) % MLKEM_Q : pa[i];
    ok &= v == b[i];
    pa[i] = 0;
  }
  return ok;
}

static void poly_in(const uint16_t *s)
{
  for (int i = 0; i < 256; i++)
    pa[i] = s[i];
}

int main(void)
{
  fir_q15(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);       if (!fir_ok()) return 2;
  fir_q15_mac(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);   if (!fir_ok()) return 3;
  fir_q15_dmac(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);  if (!fir_ok()) return 4;
  fir_q15_agu(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);   if (!fir_ok()) return 5;
  fir_q15_lp(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);    if (!fir_ok()) return 6;

  if (energy_q15(energy_x, ENERGY_N) != energy_expect) return 7;
  if (energy_q15_dmac(energy_x, ENERGY_N) != energy_expect) return 8;
  if (energy_q15_lp(energy_x, ENERGY_N) != energy_expect) return 9;

  poly_in(mlkem_a);      mlkem_ntt((int16_t *)pa);       if (!poly_ok(mlkem_ntt_a, 1)) return 10;
  poly_in(mlkem_a);      mlkem_ntt_mq(pa);               if (!poly_ok(mlkem_ntt_a, 0)) return 11;
  poly_in(mlkem_a);      mlkem_ntt_ct(pa);               if (!poly_ok(mlkem_ntt_a, 0)) return 12;
  poly_in(mlkem_ntt_a);  mlkem_invntt((int16_t *)pa);    if (!poly_ok(mlkem_invntt_expect, 1)) return 13;
  poly_in(mlkem_ntt_a);  mlkem_invntt_x(pa);             if (!poly_ok(mlkem_invntt_expect, 0)) return 14;
  return 0;
}

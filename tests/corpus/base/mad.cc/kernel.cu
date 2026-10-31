// mad.cc: multi-word multiply-add through the carry flag: mad.lo.cc, madc.hi (PTX 9.7.2.5, 9.7.2.6).
extern "C" __global__ void k_mad_cc(const unsigned *a,
                                    const unsigned *b,
                                    const unsigned *c,
                                    const unsigned *c2,
                                    unsigned *dlo,
                                    unsigned *dhi,
                                    int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned lo, hi;
  asm volatile("{\n\t"
               "mad.lo.cc.u32 %0, %2, %3, %4;\n\t"
               "madc.hi.u32 %1, %2, %3, %5;\n\t"
               "}" : "=r"(lo), "=r"(hi) : "r"(a[i]), "r"(b[i]), "r"(c[i]), "r"(c2[i]));
  dlo[i] = lo;
  dhi[i] = hi;
}

// sreg.clock: cycle counters and the global timer: %clock, %clock_hi, %clock64, %globaltimer (PTX 10.23, 10.24, 10.28).
extern "C" __global__ void k_sreg_clock(const int *in,
                                        unsigned *d32,
                                        unsigned long long *d64,
                                        unsigned long long *dg,
                                        unsigned *dhi,
                                        int *dx,
                                        int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned c0 = clock();
  long long c1 = clock64();
  unsigned long long g0 = __nvvm_read_ptx_sreg_globaltimer();
  unsigned hi;
  asm volatile("mov.u32 %0, %%clock_hi;" : "=r"(hi));
  int x = in[i];
  for (int k = 0; k < 64; k++) x = x * 1103515245 + 12345;
  unsigned c2 = clock();
  long long c3 = clock64();
  unsigned long long g1 = __nvvm_read_ptx_sreg_globaltimer();
  d32[i] = c2 - c0;
  d64[i] = c3 - c1;
  dg[i] = g1 - g0;
  dhi[i] = hi;
  dx[i] = x;
}

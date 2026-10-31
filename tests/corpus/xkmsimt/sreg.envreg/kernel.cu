// sreg.envreg: driver-defined environment registers %envreg0 to %envreg3 (PTX 10.27).
extern "C" __global__ void k_sreg_envreg(unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned e0, e1, e2, e3;
  asm volatile("mov.u32 %0, %%envreg0;" : "=r"(e0));
  asm volatile("mov.u32 %0, %%envreg1;" : "=r"(e1));
  asm volatile("mov.u32 %0, %%envreg2;" : "=r"(e2));
  asm volatile("mov.u32 %0, %%envreg3;" : "=r"(e3));
  d[4 * i] = e0; d[4 * i + 1] = e1; d[4 * i + 2] = e2; d[4 * i + 3] = e3;
}

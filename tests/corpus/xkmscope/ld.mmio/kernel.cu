// ld.mmio: memory-mapped I/O loads and stores, relaxed at system scope (PTX 9.7.9.8, 9.7.9.11).
extern "C" __global__ void k_ld_mmio(const unsigned *a, unsigned *d, unsigned *d2, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r;
  asm volatile("st.mmio.relaxed.sys.global.u32 [%0], %1;" :: "l"(&d[i]), "r"(a[i]) : "memory");
  asm volatile("ld.mmio.relaxed.sys.global.u32 %0, [%1];" : "=r"(r) : "l"(&d[i]) : "memory");
  d2[i] = r;
}

// multimem: multimem loads with reduction, stores and reductions on a multicast address (PTX 9.7.9.14).
extern "C" __global__ void k_multimem(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r;
  asm volatile("multimem.ld_reduce.relaxed.sys.global.add.u32 %0, [%1];" : "=r"(r) : "l"(&a[i]) : "memory");
  asm volatile("multimem.st.relaxed.sys.global.u32 [%0], %1;" :: "l"(&d[i]), "r"(r) : "memory");
  asm volatile("multimem.red.relaxed.sys.global.add.u32 [%0], %1;" :: "l"(&d[0]), "r"(1u) : "memory");
}

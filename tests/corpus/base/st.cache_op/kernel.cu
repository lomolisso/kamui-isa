// st.cache_op: stores with cache operators .wb, .cg, .cs, .wt (PTX 9.7.9.1).
extern "C" __global__ void k_st_cache_op(const int *a, int *d0, int *d1, int *d2, int *d3, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("st.global.wb.u32 [%0], %1;" :: "l"(&d0[i]), "r"(a[i]) : "memory");
  asm volatile("st.global.cg.u32 [%0], %1;" :: "l"(&d1[i]), "r"(a[i] + 1) : "memory");
  asm volatile("st.global.cs.u32 [%0], %1;" :: "l"(&d2[i]), "r"(a[i] + 2) : "memory");
  asm volatile("st.global.wt.u32 [%0], %1;" :: "l"(&d3[i]), "r"(a[i] + 3) : "memory");
}

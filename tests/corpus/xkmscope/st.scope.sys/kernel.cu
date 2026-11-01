// st.scope.sys: relaxed stores at .sys scope (PTX 9.7.9.11).
extern "C" __global__ void k_st_scope_sys(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("st.relaxed.sys.global.u32 [%0], %1;" :: "l"(&d[i]), "r"(a[i] * 3) : "memory");
}

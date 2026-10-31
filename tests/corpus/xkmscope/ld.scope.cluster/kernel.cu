// ld.scope.cluster: relaxed loads and stores at .cluster scope (PTX 9.7.9.8, 9.7.9.11).
extern "C" __global__ void k_ld_scope_cluster(const unsigned *a, unsigned *d, unsigned *d2, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r;
  asm volatile("st.relaxed.cluster.global.u32 [%0], %1;" :: "l"(&d[i]), "r"(a[i] ^ 5u) : "memory");
  asm volatile("ld.relaxed.cluster.global.u32 %0, [%1];" : "=r"(r) : "l"(&d[i]) : "memory");
  d2[i] = r;
}

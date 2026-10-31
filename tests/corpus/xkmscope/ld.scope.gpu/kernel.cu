// ld.scope.gpu: relaxed loads at .gpu scope (PTX 9.7.9.8).
extern "C" __global__ void k_ld_scope_gpu(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r;
  asm volatile("ld.relaxed.gpu.global.u32 %0, [%1];" : "=r"(r) : "l"(&a[i]) : "memory");
  d[i] = r + 1;
}

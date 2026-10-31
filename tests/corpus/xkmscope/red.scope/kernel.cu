// red.scope: reductions at CTA, GPU and system scope (PTX 9.7.13.6).
extern "C" __global__ void k_red_scope(const unsigned *v, unsigned *acc, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("red.relaxed.cta.global.add.u32 [%0], %1;" :: "l"(&acc[0]), "r"(v[i]) : "memory");
  asm volatile("red.relaxed.gpu.global.add.u32 [%0], %1;" :: "l"(&acc[1]), "r"(v[i]) : "memory");
  asm volatile("red.relaxed.sys.global.add.u32 [%0], %1;" :: "l"(&acc[2]), "r"(v[i]) : "memory");
}

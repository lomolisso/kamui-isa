// red.generic: reductions through a generic address (PTX 9.7.13.6).
extern "C" __global__ void k_red_generic(const unsigned *val, unsigned *acc, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("red.add.u32 [%0], %1;" :: "l"(&acc[i & 3]), "r"(val[i]) : "memory");
  asm volatile("red.max.u32 [%0], %1;" :: "l"(&acc[4]), "r"(val[i]) : "memory");
}

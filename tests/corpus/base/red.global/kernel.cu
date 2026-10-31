// red.global: global reductions without a result: add, min, max, and, or, xor, inc, dec, f32 add (PTX 9.7.13.6).
extern "C" __global__ void k_red_global(const unsigned *val, unsigned *acc, float *accf, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned v = val[i];
  asm volatile("red.global.add.u32 [%0], %1;" :: "l"(&acc[0]), "r"(v) : "memory");
  asm volatile("red.global.min.u32 [%0], %1;" :: "l"(&acc[1]), "r"(v) : "memory");
  asm volatile("red.global.max.u32 [%0], %1;" :: "l"(&acc[2]), "r"(v) : "memory");
  asm volatile("red.global.and.b32 [%0], %1;" :: "l"(&acc[3]), "r"(v | 0xff00u) : "memory");
  asm volatile("red.global.or.b32 [%0], %1;" :: "l"(&acc[4]), "r"(v) : "memory");
  asm volatile("red.global.xor.b32 [%0], %1;" :: "l"(&acc[5]), "r"(v) : "memory");
  asm volatile("red.global.inc.u32 [%0], %1;" :: "l"(&acc[6]), "r"(1000u) : "memory");
  asm volatile("red.global.dec.u32 [%0], %1;" :: "l"(&acc[7]), "r"(1000u) : "memory");
  asm volatile("red.global.add.f32 [%0], %1;" :: "l"(&accf[0]), "f"((float)v * 0.25f) : "memory");
}

// red.shared: shared-memory reductions: add, min, max, and, or, xor (PTX 9.7.13.6).
extern "C" __global__ void k_red_shared(const unsigned *val, unsigned *fin) {
  __shared__ unsigned s[6];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t < 6) s[t] = (t == 1 || t == 3) ? 0xffffffffu : 0u;
  __syncthreads();
  unsigned v = val[i];
  unsigned base = (unsigned)__cvta_generic_to_shared(&s[0]);
  asm volatile("red.shared.add.u32 [%0], %1;" :: "r"(base), "r"(v) : "memory");
  asm volatile("red.shared.min.u32 [%0+4], %1;" :: "r"(base), "r"(v) : "memory");
  asm volatile("red.shared.max.u32 [%0+8], %1;" :: "r"(base), "r"(v) : "memory");
  asm volatile("red.shared.and.b32 [%0+12], %1;" :: "r"(base), "r"(v | 0xff00u) : "memory");
  asm volatile("red.shared.or.b32 [%0+16], %1;" :: "r"(base), "r"(v) : "memory");
  asm volatile("red.shared.xor.b32 [%0+20], %1;" :: "r"(base), "r"(v) : "memory");
  __syncthreads();
  if (t < 6) fin[blockIdx.x * 6 + t] = s[t];
}

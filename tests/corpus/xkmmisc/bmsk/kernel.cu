// bmsk: build a bit mask from a position and a width, clamp and wrap modes (PTX 9.7.1.22).
extern "C" __global__ void k_bmsk(const unsigned *a, const unsigned *b, unsigned *d0, unsigned *d1, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r0, r1;
  asm volatile("bmsk.clamp.b32 %0, %1, %2;" : "=r"(r0) : "r"(a[i] & 63), "r"(b[i]));
  asm volatile("bmsk.wrap.b32 %0, %1, %2;" : "=r"(r1) : "r"(a[i] & 63), "r"(b[i]));
  d0[i] = r0; d1[i] = r1;
}

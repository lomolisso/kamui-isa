// stmatrix: store warp fragments as 8x8 b16 matrices into shared memory (PTX 9.7.14.5.16).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }

extern "C" __global__ void k_stmatrix(const unsigned *in, unsigned short *d) {
  __shared__ __align__(16) unsigned short s[2][256];
  int t = threadIdx.x, w = t >> 5, lane = t & 31;
  unsigned addr = smem(&s[w][lane * 8]);
  asm volatile("stmatrix.sync.aligned.m8n8.x4.shared.b16 [%0], {%1, %2, %3, %4};"
               :: "r"(addr), "r"(in[4 * t]), "r"(in[4 * t + 1]), "r"(in[4 * t + 2]), "r"(in[4 * t + 3]) : "memory");
  __syncwarp();
  for (int k = 0; k < 8; k++) d[w * 256 + lane * 8 + k] = s[w][lane * 8 + k];
}

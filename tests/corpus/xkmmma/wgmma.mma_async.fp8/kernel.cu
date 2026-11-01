// wgmma.mma_async.fp8: warpgroup MMA on e4m3, m64n8k32 (PTX 9.7.15.5.2).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
// Shared-memory matrix descriptor, no swizzle: start address, leading and stride byte offsets (all >> 4).
__device__ __forceinline__ unsigned long long desc(const void *p, unsigned lbo, unsigned sbo) {
  return (unsigned long long)((smem(p) & 0x3ffff) >> 4) | ((unsigned long long)((lbo & 0x3ffff) >> 4) << 16)
       | ((unsigned long long)((sbo & 0x3ffff) >> 4) << 32);
}

extern "C" __global__ void k_wgmma_mma_async_fp8(const unsigned *a, const unsigned *b, float *d) {
  __shared__ __align__(128) unsigned sa[512];
  __shared__ __align__(128) unsigned sb[128];
  int t = threadIdx.x;
  for (int k = 0; k < 4; k++) sa[4 * t + k] = a[4 * t + k];
  sb[t] = b[t];
  asm volatile("fence.proxy.async.shared::cta;" ::: "memory");
  __syncthreads();
  unsigned long long da = desc(sa, 128, 256), db = desc(sb, 128, 256);
  float r[4] = {0, 0, 0, 0};
  asm volatile("wgmma.fence.sync.aligned;" ::: "memory");
  asm volatile("{ .reg .pred p; setp.ne.b32 p, %6, 0;\n\t"
               "wgmma.mma_async.sync.aligned.m64n8k32.f32.e4m3.e4m3 {%0, %1, %2, %3}, %4, %5, p, 1, 1; }"
               : "+f"(r[0]), "+f"(r[1]), "+f"(r[2]), "+f"(r[3]) : "l"(da), "l"(db), "r"(1) : "memory");
  asm volatile("wgmma.commit_group.sync.aligned;" ::: "memory");
  asm volatile("wgmma.wait_group.sync.aligned 0;" ::: "memory");
  for (int k = 0; k < 4; k++) d[4 * t + k] = r[k];
}

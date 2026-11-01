// tensormap.cp_fenceproxy: copy a tensor map from shared to global memory with a tensormap proxy fence, then acquire it (PTX 9.7.13.16, 9.7.13.4).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }

extern "C" __global__ void k_tensormap_cp_fenceproxy(const unsigned long long *src, unsigned long long *dst) {
  __shared__ __align__(128) unsigned long long s[16];
  int t = threadIdx.x;
  if (t < 16) s[t] = src[t];
  __syncwarp();
  asm volatile("tensormap.cp_fenceproxy.global.shared::cta.tensormap::generic.release.gpu.sync.aligned [%0], [%1], 128;"
               :: "l"(dst), "r"(smem(s)) : "memory");
  asm volatile("fence.proxy.tensormap::generic.acquire.gpu [%0], 128;" :: "l"(dst) : "memory");
  asm volatile("fence.proxy.tensormap::generic.release.gpu;" ::: "memory");
}

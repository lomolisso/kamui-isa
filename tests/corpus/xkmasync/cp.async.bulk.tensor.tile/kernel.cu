// cp.async.bulk.tensor.tile: TMA load of a 32x8 box of a 64x32 u32 tensor into shared memory, tile mode, after prefetching the tensor map (PTX 9.7.9.25.5.2, 9.7.9.15).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
struct __align__(64) TensorMap { unsigned long long w[16]; };
__device__ __forceinline__ void wait_parity(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.shared::cta.b64 p, [%1], %2; selp.u32 %0, 1, 0, p; }"
                 : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_cp_async_bulk_tensor_tile(const unsigned *g,
                                                       const __grid_constant__ TensorMap tm,
                                                       unsigned *d) {
  __shared__ unsigned long long bar;
  __shared__ __align__(128) unsigned s[256];
  int t = threadIdx.x;
  unsigned b = smem(&bar);
  int x = 32 * (blockIdx.x & 1), y = 8 * (blockIdx.x >> 1);
  if (t == 0) {
    asm volatile("prefetch.tensormap [%0];" :: "l"(&tm) : "memory");
    asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;" :: "r"(b) : "memory");
  }
  __syncthreads();
  if (t == 0) {
    asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], 1024;" :: "r"(b) : "memory");
    asm volatile("cp.async.bulk.tensor.2d.shared::cluster.global.tile.mbarrier::complete_tx::bytes [%0], [%1, {%2, %3}], [%4];"
                 :: "r"(smem(s)), "l"(&tm), "r"(x), "r"(y), "r"(b) : "memory");
  }
  wait_parity(b, 0);
  d[256 * blockIdx.x + 2 * t] = s[2 * t];
  d[256 * blockIdx.x + 2 * t + 1] = s[2 * t + 1];
}

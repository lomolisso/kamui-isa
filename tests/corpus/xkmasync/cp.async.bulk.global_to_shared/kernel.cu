// cp.async.bulk.global_to_shared: bulk copy of 2 KB from global to shared memory, completed through an mbarrier (PTX 9.7.9.25.4.1).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
__device__ __forceinline__ void wait_parity(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.shared::cta.b64 p, [%1], %2; selp.u32 %0, 1, 0, p; }"
                 : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_cp_async_bulk_global_to_shared(const int *in, int *d) {
  __shared__ unsigned long long bar;
  __shared__ __align__(128) int s[512];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  unsigned b = smem(&bar);
  if (t == 0) asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;" :: "r"(b) : "memory");
  __syncthreads();
  if (t == 0) {
    asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], 2048;" :: "r"(b) : "memory");
    asm volatile("cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes [%0], [%1], 2048, [%2];"
                 :: "r"(smem(s)), "l"(&in[512 * blockIdx.x]), "r"(b) : "memory");
  }
  wait_parity(b, 0);
  for (int k = 0; k < 4; k++) d[512 * blockIdx.x + 4 * t + k] = s[4 * t + k] + 1;
}

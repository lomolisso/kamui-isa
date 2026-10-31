// mbarrier.try_wait: transaction counts and phase waits: expect_tx, complete_tx, arrive.expect_tx, try_wait and try_wait.parity (PTX 9.7.13.15).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
__device__ __forceinline__ void wait_parity(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.shared::cta.b64 p, [%1], %2; selp.u32 %0, 1, 0, p; }"
                 : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_mbarrier_try_wait(const int *in, int *d, int *d2) {
  __shared__ unsigned long long bar;
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  unsigned b = smem(&bar);
  if (t == 0) asm volatile("mbarrier.init.shared::cta.b64 [%0], 128;" :: "r"(b) : "memory");
  __syncthreads();
  s[t] = in[i];
  if (t == 0) {
    asm volatile("mbarrier.expect_tx.relaxed.cta.shared::cta.b64 [%0], 64;" :: "r"(b) : "memory");
    asm volatile("mbarrier.complete_tx.relaxed.cta.shared::cta.b64 [%0], 64;" :: "r"(b) : "memory");
  }
  unsigned long long st;
  asm volatile("mbarrier.arrive.shared::cta.b64 %0, [%1];" : "=l"(st) : "r"(b) : "memory");
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.shared::cta.b64 p, [%1], %2; selp.u32 %0, 1, 0, p; }"
                 : "=r"(done) : "r"(b), "l"(st) : "memory");
  d[i] = s[(t + 5) & 127];
  if (t == 0) asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 %0, [%1], 0;" : "=l"(st) : "r"(b) : "memory");
  else asm volatile("mbarrier.arrive.shared::cta.b64 %0, [%1];" : "=l"(st) : "r"(b) : "memory");
  wait_parity(b, 1);
  d2[i] = 1;
}

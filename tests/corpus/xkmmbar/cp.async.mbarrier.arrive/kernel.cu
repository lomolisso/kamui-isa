// cp.async.mbarrier.arrive: make an mbarrier track the completion of earlier cp.async copies (PTX 9.7.13.15.15).
#define AS3(T, p) ((__attribute__((address_space(3))) T *)(p))
#define AS1(T, p) ((__attribute__((address_space(1))) T *)(p))
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
__device__ __forceinline__ void wait_parity(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.shared::cta.b64 p, [%1], %2; selp.u32 %0, 1, 0, p; }"
                 : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_cp_async_mbarrier_arrive(const int *in, int *d) {
  __shared__ unsigned long long bar;
  __shared__ __align__(16) int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t == 0) __nvvm_mbarrier_init_shared(AS3(long, &bar), 128);
  __syncthreads();
  __nvvm_cp_async_ca_shared_global_4(AS3(void, &s[t]), AS1(const void, &in[i]));
  __nvvm_cp_async_mbarrier_arrive_noinc_shared(AS3(long, &bar));
  wait_parity(smem(&bar), 0);
  d[i] = s[127 - t];
}

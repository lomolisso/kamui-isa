// st.async: asynchronous stores into the peer CTA's shared memory, tracked by the peer's mbarrier; cluster-scope waits and the mbarrier_init fence (PTX 9.7.9.12, 9.7.13.15, 9.7.13.4).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
__device__ __forceinline__ void wait_parity_cluster(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.acquire.cluster.shared::cta.b64 p, [%1], %2;"
                 " selp.u32 %0, 1, 0, p; }" : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_st_async(const int *in, int *d) {
  __shared__ unsigned long long bar;
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank(), b = smem(&bar);
  if (t == 0) {
    asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;" :: "r"(b) : "memory");
    asm volatile("fence.mbarrier_init.release.cluster;" ::: "memory");
  }
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  if (t == 0) asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], 512;" :: "r"(b) : "memory");
  unsigned rs, rb;
  asm volatile("mapa.shared::cluster.u32 %0, %1, %2;" : "=r"(rs) : "r"(smem(&s[t])), "r"(rank ^ 1));
  asm volatile("mapa.shared::cluster.u32 %0, %1, %2;" : "=r"(rb) : "r"(b), "r"(rank ^ 1));
  asm volatile("st.async.shared::cluster.mbarrier::complete_tx::bytes.u32 [%0], %1, [%2];"
               :: "r"(rs), "r"(in[i] * 7), "r"(rb) : "memory");
  wait_parity_cluster(b, 0);
  d[i] = s[t];
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
}

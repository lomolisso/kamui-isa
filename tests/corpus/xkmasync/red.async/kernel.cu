// red.async: asynchronous reductions into the peer CTA's shared memory, and a remote mbarrier arrive (PTX 9.7.13.7, 9.7.13.15.13).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
__device__ __forceinline__ void wait_parity_cluster(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.acquire.cluster.shared::cta.b64 p, [%1], %2;"
                 " selp.u32 %0, 1, 0, p; }" : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_red_async(const unsigned *v, unsigned *d) {
  __shared__ unsigned long long bar;
  __shared__ unsigned s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank(), b = smem(&bar);
  s[t] = 1000u * t;
  if (t == 0) {
    asm volatile("mbarrier.init.shared::cta.b64 [%0], 2;" :: "r"(b) : "memory");
    asm volatile("fence.mbarrier_init.release.cluster;" ::: "memory");
  }
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  unsigned rs, rb;
  asm volatile("mapa.shared::cluster.u32 %0, %1, %2;" : "=r"(rs) : "r"(smem(&s[t])), "r"(rank ^ 1));
  asm volatile("mapa.shared::cluster.u32 %0, %1, %2;" : "=r"(rb) : "r"(b), "r"(rank ^ 1));
  if (t == 0) {
    asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], 512;" :: "r"(b) : "memory");
    asm volatile("mbarrier.arrive.release.cluster.shared::cluster.b64 _, [%0];" :: "r"(rb) : "memory");
  }
  asm volatile("red.async.relaxed.cluster.shared::cluster.mbarrier::complete_tx::bytes.add.u32 [%0], %1, [%2];"
               :: "r"(rs), "r"(v[i]), "r"(rb) : "memory");
  wait_parity_cluster(b, 0);
  d[i] = s[t];
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
}

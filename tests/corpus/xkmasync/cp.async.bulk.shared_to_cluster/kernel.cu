// cp.async.bulk.shared_to_cluster: bulk copy from CTA 0's shared memory into CTA 1's, completed through CTA 1's mbarrier (PTX 9.7.9.25.4.1).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
__device__ __forceinline__ void wait_parity_cluster(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.acquire.cluster.shared::cta.b64 p, [%1], %2;"
                 " selp.u32 %0, 1, 0, p; }" : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_cp_async_bulk_shared_to_cluster(const int *in, int *d) {
  __shared__ unsigned long long bar;
  __shared__ __align__(128) int s[512];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank(), b = smem(&bar);
  for (int k = 0; k < 4; k++) s[4 * t + k] = in[512 * blockIdx.x + 4 * t + k];
  if (t == 0) {
    asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;" :: "r"(b) : "memory");
    asm volatile("fence.mbarrier_init.release.cluster;" ::: "memory");
  }
  asm volatile("fence.proxy.async.shared::cta;" ::: "memory");
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  if (rank == 1 && t == 0) asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], 2048;" :: "r"(b) : "memory");
  if (rank == 0 && t == 0) {
    unsigned rs, rb;
    asm volatile("mapa.shared::cluster.u32 %0, %1, 1;" : "=r"(rs) : "r"(smem(s)));
    asm volatile("mapa.shared::cluster.u32 %0, %1, 1;" : "=r"(rb) : "r"(b));
    asm volatile("cp.async.bulk.shared::cluster.shared::cta.mbarrier::complete_tx::bytes [%0], [%1], 2048, [%2];"
                 :: "r"(rs), "r"(smem(s)), "r"(rb) : "memory");
  }
  if (rank == 1) {
    wait_parity_cluster(b, 0);
    for (int k = 0; k < 4; k++) d[512 * (blockIdx.x / 2) + 4 * t + k] = s[4 * t + k];
  }
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
}

// cp.async.bulk.multicast: bulk copy from global memory into the shared memory of both CTAs of the cluster at once (PTX 9.7.9.25.4.1).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
__device__ __forceinline__ void wait_parity_cluster(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.acquire.cluster.shared::cta.b64 p, [%1], %2;"
                 " selp.u32 %0, 1, 0, p; }" : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_cp_async_bulk_multicast(const int *in, int *d) {
  __shared__ unsigned long long bar;
  __shared__ __align__(128) int s[512];
  int t = threadIdx.x;
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank(), b = smem(&bar);
  if (t == 0) {
    asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;" :: "r"(b) : "memory");
    asm volatile("fence.mbarrier_init.release.cluster;" ::: "memory");
    asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], 2048;" :: "r"(b) : "memory");
  }
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  if (rank == 0 && t == 0)
    asm volatile("cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes.multicast::cluster [%0], [%1], 2048, [%2], %3;"
                 :: "r"(smem(s)), "l"(&in[512 * (blockIdx.x / 2)]), "r"(b), "h"((unsigned short)3) : "memory");
  wait_parity_cluster(b, 0);
  for (int k = 0; k < 4; k++) d[512 * blockIdx.x + 4 * t + k] = s[4 * t + k];
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
}

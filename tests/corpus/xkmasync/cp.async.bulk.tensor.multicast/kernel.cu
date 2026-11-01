// cp.async.bulk.tensor.multicast: TMA load multicast to both CTAs of the cluster (PTX 9.7.9.25.5.2).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
struct __align__(64) TensorMap { unsigned long long w[16]; };
__device__ __forceinline__ void wait_parity_cluster(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.acquire.cluster.shared::cta.b64 p, [%1], %2;"
                 " selp.u32 %0, 1, 0, p; }" : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_cp_async_bulk_tensor_multicast(const unsigned *g,
                                                            const __grid_constant__ TensorMap tm,
                                                            unsigned *d) {
  __shared__ unsigned long long bar;
  __shared__ __align__(128) unsigned s[256];
  int t = threadIdx.x;
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank(), b = smem(&bar);
  if (t == 0) {
    asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;" :: "r"(b) : "memory");
    asm volatile("fence.mbarrier_init.release.cluster;" ::: "memory");
  }
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  // After the barrier: the transaction count may go below zero if the peer's copy lands first, which is allowed.
  if (t == 0) asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], 1024;" :: "r"(b) : "memory");
  if (rank == 0 && t == 0)
    asm volatile("cp.async.bulk.tensor.2d.shared::cluster.global.tile.mbarrier::complete_tx::bytes.multicast::cluster"
                 " [%0], [%1, {%2, %3}], [%4], %5;"
                 :: "r"(smem(s)), "l"(&tm), "r"(0), "r"(8 * (int)(blockIdx.x / 2)), "r"(b), "h"((unsigned short)3) : "memory");
  wait_parity_cluster(b, 0);
  d[256 * blockIdx.x + 2 * t] = s[2 * t];
  d[256 * blockIdx.x + 2 * t + 1] = s[2 * t + 1];
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
}

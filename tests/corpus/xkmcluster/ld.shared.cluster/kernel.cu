// ld.shared::cluster: loads and stores to another CTA's shared memory through shared::cluster addresses (PTX 9.7.9.8, 9.7.9.11).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }

extern "C" __global__ void k_ld_shared_cluster(const int *in, int *d) {
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank(), remote;
  asm volatile("mapa.shared::cluster.u32 %0, %1, %2;" : "=r"(remote) : "r"(smem(&s[t])), "r"(rank ^ 1));
  asm volatile("st.shared::cluster.u32 [%0], %1;" :: "r"(remote), "r"(in[i] * 3) : "memory");
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  int v;
  unsigned mine;
  asm volatile("mapa.shared::cluster.u32 %0, %1, %2;" : "=r"(mine) : "r"(smem(&s[127 - t])), "r"(rank));
  asm volatile("ld.shared::cluster.u32 %0, [%1];" : "=r"(v) : "r"(mine) : "memory");
  d[i] = v;
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
}

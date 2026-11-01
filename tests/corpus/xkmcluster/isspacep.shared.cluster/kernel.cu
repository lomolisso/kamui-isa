// isspacep.shared::cluster: test and convert shared::cluster addresses (PTX 9.7.9.19, 9.7.9.20).
extern "C" __global__ void k_isspacep_shared_cluster(const int *in, unsigned *d) {
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  s[t] = in[i];
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank();
  void *peer = __nvvm_mapa(&s[t], (int)(rank ^ 1));
  unsigned long long c;
  asm volatile("cvta.to.shared::cluster.u64 %0, %1;" : "=l"(c) : "l"(peer));
  unsigned long long g;
  asm volatile("cvta.shared::cluster.u64 %0, %1;" : "=l"(g) : "l"(c));
  d[i] = __nvvm_isspacep_shared_cluster(peer) | (__nvvm_isspacep_shared_cluster(&in[i]) << 1) | (*(int *)g == s[t] ? 0 : 4);
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
}

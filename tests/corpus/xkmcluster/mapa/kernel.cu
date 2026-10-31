// mapa: distributed shared memory: map a shared address into another CTA of the cluster, read it there, find its rank; cluster barriers around it (PTX 9.7.9.23, 9.7.9.24, 9.7.13.3).
extern "C" __global__ void k_mapa(const int *in, int *d, unsigned *dr) {
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank();
  s[t] = in[i];
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  int *peer = (int *)__nvvm_mapa(&s[127 - t], (int)(rank ^ 1));
  d[i] = *peer;
  dr[i] = __nvvm_getctarank(peer);
  __nvvm_barrier_cluster_arrive_relaxed();
  __nvvm_barrier_cluster_wait();
}

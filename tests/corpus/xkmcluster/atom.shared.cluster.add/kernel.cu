// atom.shared::cluster.add: atomics and reductions on the shared memory of CTA 0 of the cluster (PTX 9.7.13.5, 9.7.13.6).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }

extern "C" __global__ void k_atom_shared_cluster_add(const unsigned *v, unsigned *old, unsigned *fin) {
  __shared__ unsigned cnt[2];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t < 2) cnt[t] = 0;
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  unsigned r0, r1, o;
  asm volatile("mapa.shared::cluster.u32 %0, %1, 0;" : "=r"(r0) : "r"(smem(&cnt[0])));
  asm volatile("mapa.shared::cluster.u32 %0, %1, 0;" : "=r"(r1) : "r"(smem(&cnt[1])));
  asm volatile("atom.shared::cluster.add.u32 %0, [%1], %2;" : "=r"(o) : "r"(r0), "r"(v[i]) : "memory");
  asm volatile("red.shared::cluster.add.u32 [%0], %1;" :: "r"(r1), "r"(1u) : "memory");
  old[i] = o;
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  if (__nvvm_read_ptx_sreg_cluster_ctarank() == 0 && t < 2) fin[(blockIdx.x / 2) * 2 + t] = cnt[t];
}

// sreg.cluster_ctarank: cluster special registers: %cluster_ctarank, %cluster_nctarank, %clusterid, %nclusterid, %cluster_ctaid, %cluster_nctaid, %is_explicit_cluster (PTX 10.11 to 10.17).
extern "C" __global__ void k_sreg_cluster_ctarank(unsigned *d) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  d[8 * i + 0] = __nvvm_read_ptx_sreg_cluster_ctarank();
  d[8 * i + 1] = __nvvm_read_ptx_sreg_cluster_nctarank();
  d[8 * i + 2] = __nvvm_read_ptx_sreg_clusterid_x();
  d[8 * i + 3] = __nvvm_read_ptx_sreg_nclusterid_x();
  d[8 * i + 4] = __nvvm_read_ptx_sreg_cluster_ctaid_x();
  d[8 * i + 5] = __nvvm_read_ptx_sreg_cluster_nctaid_x();
  d[8 * i + 6] = __nvvm_is_explicit_cluster();
  unsigned aggr;
  asm volatile("mov.u32 %0, %%aggr_smem_size;" : "=r"(aggr));
  d[8 * i + 7] = aggr;
}

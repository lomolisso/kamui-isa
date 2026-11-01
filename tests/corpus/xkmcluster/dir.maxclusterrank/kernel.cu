// dir.maxclusterrank: maximum CTAs per cluster from __launch_bounds__ (PTX 11.7.3).
extern "C" __global__ void __launch_bounds__(128, 1, 4) k_dir_maxclusterrank(unsigned *d) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  d[i] = __nvvm_read_ptx_sreg_cluster_nctarank();
}

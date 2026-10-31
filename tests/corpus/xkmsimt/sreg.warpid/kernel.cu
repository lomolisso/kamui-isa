// sreg.warpid: hardware placement ids: %warpid, %nwarpid, %smid, %nsmid, %gridid (PTX 10.4, 10.5, 10.8 to 10.10).
extern "C" __global__ void k_sreg_warpid(unsigned *d, unsigned long long *g, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[4 * i + 0] = __nvvm_read_ptx_sreg_warpid();
  d[4 * i + 1] = __nvvm_read_ptx_sreg_nwarpid();
  d[4 * i + 2] = __nvvm_read_ptx_sreg_smid();
  d[4 * i + 3] = __nvvm_read_ptx_sreg_nsmid();
  g[i] = __nvvm_read_ptx_sreg_gridid();
}

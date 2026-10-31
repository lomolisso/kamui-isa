// sreg.laneid: lane id and lane masks: %laneid, %lanemask_eq/le/lt/ge/gt (PTX 10.3, 10.18 to 10.22).
extern "C" __global__ void k_sreg_laneid(unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[6 * i + 0] = __nvvm_read_ptx_sreg_laneid();
  d[6 * i + 1] = __nvvm_read_ptx_sreg_lanemask_eq();
  d[6 * i + 2] = __nvvm_read_ptx_sreg_lanemask_le();
  d[6 * i + 3] = __nvvm_read_ptx_sreg_lanemask_lt();
  d[6 * i + 4] = __nvvm_read_ptx_sreg_lanemask_ge();
  d[6 * i + 5] = __nvvm_read_ptx_sreg_lanemask_gt();
}

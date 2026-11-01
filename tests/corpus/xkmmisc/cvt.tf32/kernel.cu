// cvt.tf32: round f32 to tf32 (10-bit mantissa), nearest away from zero (PTX 9.7.9.21).
extern "C" __global__ void k_cvt_tf32(const float *f, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __nvvm_f2tf32_rna(f[i]);
}

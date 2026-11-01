// min.fp.nan: NaN-propagating min and max, and the .xorsign.abs forms (PTX 9.7.3.11, 9.7.3.12).
extern "C" __global__ void k_min_fp_nan(const float *a, const float *b, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float x = (i & 7) == 0 ? __uint_as_float(0x7fc00000u) : a[i];
  d[4 * i + 0] = __nvvm_fmin_nan_f(x, b[i]);
  d[4 * i + 1] = __nvvm_fmax_nan_f(x, b[i]);
  d[4 * i + 2] = __nvvm_fmin_xorsign_abs_f(x, b[i]);
  d[4 * i + 3] = __nvvm_fmax_xorsign_abs_f(x, b[i]);
}

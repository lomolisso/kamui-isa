// abs.fp: floating-point abs, f32 and f64 (PTX 9.7.3.9).
extern "C" __global__ void k_abs_fp(const float *a, float *d, const double *a64, double *d64, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = fabsf(a[i]);
  d64[i] = fabs(a64[i]);
}

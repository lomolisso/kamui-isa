// neg.fp: floating-point neg, f32 and f64 (PTX 9.7.3.10).
extern "C" __global__ void k_neg_fp(const float *a, float *d, const double *a64, double *d64, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = -a[i];
  d64[i] = -a64[i];
}

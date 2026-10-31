// sqrt.rn: IEEE square root, f32 and f64 (PTX 9.7.3.15).
extern "C" __global__ void k_sqrt_rn(const float *a,
                                     float *d,
                                     const double *a64,
                                     double *d64,
                                     float *dc,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __fsqrt_rn(a[i]);
  d64[i] = sqrt(a64[i]);
  dc[i] = sqrtf(a[i]);
}

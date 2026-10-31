// min.fp: floating-point minimum, f32 and f64 (PTX 9.7.3.11).
extern "C" __global__ void k_min_fp(const float *a,
                                    const float *b,
                                    float *d,
                                    const double *a64,
                                    const double *b64,
                                    double *d64,
                                    int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = fminf(a[i], b[i]);
  d64[i] = fmin(a64[i], b64[i]);
}

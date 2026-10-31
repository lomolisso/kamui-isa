// mul.fp: floating-point mul, f32 and f64, round to nearest (PTX 9.7.3.5).
extern "C" __global__ void k_mul_fp(const float *a,
                                    const float *b,
                                    float *d,
                                    const double *a64,
                                    const double *b64,
                                    double *d64,
                                    int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i] * b[i];
  d64[i] = a64[i] * b64[i];
}

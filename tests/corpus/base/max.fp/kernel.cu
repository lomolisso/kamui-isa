// max.fp: floating-point maximum, f32 and f64 (PTX 9.7.3.12).
extern "C" __global__ void k_max_fp(const float *a,
                                    const float *b,
                                    float *d,
                                    const double *a64,
                                    const double *b64,
                                    double *d64,
                                    int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = fmaxf(a[i], b[i]);
  d64[i] = fmax(a64[i], b64[i]);
}

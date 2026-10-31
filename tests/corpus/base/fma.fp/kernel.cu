// fma.fp: fused multiply-add, f32 and f64 (PTX 9.7.3.6).
extern "C" __global__ void k_fma_fp(const float *a,
                                    const float *b,
                                    const float *c,
                                    float *d,
                                    const double *a64,
                                    const double *b64,
                                    const double *c64,
                                    double *d64,
                                    int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = fmaf(a[i], b[i], c[i]);
  d64[i] = fma(a64[i], b64[i], c64[i]);
}

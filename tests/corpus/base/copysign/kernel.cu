// copysign: copy the sign of one float onto another, f32 and f64 (PTX 9.7.3.2).
extern "C" __global__ void k_copysign(const float *a,
                                      const float *b,
                                      float *d,
                                      const double *a64,
                                      const double *b64,
                                      double *d64,
                                      int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = copysignf(a[i], b[i]);
  double r;
  asm volatile("copysign.f64 %0, %1, %2;" : "=d"(r) : "d"(b64[i]), "d"(a64[i]));
  d64[i] = r;
}

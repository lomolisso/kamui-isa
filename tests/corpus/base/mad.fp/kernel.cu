// mad.fp: floating-point mad, which is fma on sm_20 and later (PTX 9.7.3.7).
extern "C" __global__ void k_mad_fp(const float *a, const float *b, const float *c, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("mad.rn.f32 %0, %1, %2, %3;" : "=f"(r) : "f"(a[i]), "f"(b[i]), "f"(c[i]));
  d[i] = r;
}

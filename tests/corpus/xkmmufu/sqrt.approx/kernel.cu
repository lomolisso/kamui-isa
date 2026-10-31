// sqrt.approx: approximate sqrt (PTX 9.7.3.15).
extern "C" __global__ void k_sqrt_approx(const float *a, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("sqrt.approx.f32 %0, %1;" : "=f"(r) : "f"(a[i]));
  d[i] = r;
}

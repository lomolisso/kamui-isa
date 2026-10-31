// cos: approximate cos (PTX 9.7.3.19).
extern "C" __global__ void k_cos(const float *a, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("cos.approx.f32 %0, %1;" : "=f"(r) : "f"(a[i]));
  d[i] = r;
}

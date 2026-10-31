// lg2: approximate lg2 (PTX 9.7.3.20).
extern "C" __global__ void k_lg2(const float *a, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("lg2.approx.f32 %0, %1;" : "=f"(r) : "f"(a[i]));
  d[i] = r;
}

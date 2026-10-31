// ex2: approximate ex2 (PTX 9.7.3.21).
extern "C" __global__ void k_ex2(const float *a, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("ex2.approx.f32 %0, %1;" : "=f"(r) : "f"(a[i]));
  d[i] = r;
}

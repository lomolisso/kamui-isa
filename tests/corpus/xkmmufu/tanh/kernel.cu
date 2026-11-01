// tanh: approximate tanh on f32 (PTX 9.7.3.22).
extern "C" __global__ void k_tanh(const float *a, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("tanh.approx.f32 %0, %1;" : "=f"(r) : "f"(a[i]));
  d[i] = r;
}

// rsqrt: approximate rsqrt (PTX 9.7.3.16).
extern "C" __global__ void k_rsqrt(const float *a, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("rsqrt.approx.f32 %0, %1;" : "=f"(r) : "f"(a[i]));
  d[i] = r;
}

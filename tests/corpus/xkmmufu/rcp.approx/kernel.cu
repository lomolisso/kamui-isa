// rcp.approx: approximate reciprocal (PTX 9.7.3.13).
extern "C" __global__ void k_rcp_approx(const float *a, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("rcp.approx.f32 %0, %1;" : "=f"(r) : "f"(a[i]));
  d[i] = r;
}

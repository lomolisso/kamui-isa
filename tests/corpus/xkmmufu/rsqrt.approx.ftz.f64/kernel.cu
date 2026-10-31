// rsqrt.approx.ftz.f64: approximate rsqrt (PTX 9.7.3.17).
extern "C" __global__ void k_rsqrt_approx_ftz_f64(const double *a, double *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  double r;
  asm volatile("rsqrt.approx.ftz.f64 %0, %1;" : "=d"(r) : "d"(a[i]));
  d[i] = r;
}

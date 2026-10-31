// rcp.approx.ftz.f64: approximate f64 reciprocal, about 20 bits (PTX 9.7.3.14).
extern "C" __global__ void k_rcp_approx_ftz_f64(const double *a, double *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  double r;
  asm volatile("rcp.approx.ftz.f64 %0, %1;" : "=d"(r) : "d"(a[i]));
  d[i] = r;
}

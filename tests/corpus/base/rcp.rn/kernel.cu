// rcp.rn: IEEE reciprocal, f32 and f64 (PTX 9.7.3.13).
extern "C" __global__ void k_rcp_rn(const float *a, float *d, const double *a64, double *d64, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __frcp_rn(a[i]);
  d64[i] = __drcp_rn(a64[i]);
}

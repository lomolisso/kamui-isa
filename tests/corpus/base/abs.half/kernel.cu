// abs.half: half-precision absolute value (PTX 9.7.4.6).
extern "C" __global__ void k_abs_half(const _Float16 *a, _Float16 *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __builtin_fabsf16(a[i]);
}

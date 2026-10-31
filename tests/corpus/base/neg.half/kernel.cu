// neg.half: half-precision negate (PTX 9.7.4.5).
extern "C" __global__ void k_neg_half(const _Float16 *a, _Float16 *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = -a[i];
}

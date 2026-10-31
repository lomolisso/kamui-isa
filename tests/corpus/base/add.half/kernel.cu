// add.half: half-precision add (PTX 9.7.4.1).
extern "C" __global__ void k_add_half(const _Float16 *a, const _Float16 *b, _Float16 *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i] + b[i];
}

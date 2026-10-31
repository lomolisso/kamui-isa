// setp.half: half-precision compare to a predicate (PTX 9.7.7.2).
extern "C" __global__ void k_setp_half(const _Float16 *a, const _Float16 *b, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = (a[i] < b[i]) | ((a[i] >= b[i]) << 1) | ((a[i] == b[i]) << 2);
}

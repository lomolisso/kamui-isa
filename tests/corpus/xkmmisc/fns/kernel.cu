// fns: find the n-th set bit (PTX 9.7.1.17).
extern "C" __global__ void k_fns(const unsigned *mask, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __fns(mask[i], (unsigned)(i & 31), (int)(i % 7) - 3);
}

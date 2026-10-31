// neg.int: integer negate, 32 and 64 bits (PTX 9.7.1.11).
extern "C" __global__ void k_neg_int(const int *a32, int *d32, const long long *a64, long long *d64, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = -a32[i];
  d64[i] = -a64[i];
}

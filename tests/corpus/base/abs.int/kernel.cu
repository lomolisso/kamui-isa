// abs.int: integer absolute value, 32 and 64 bits (PTX 9.7.1.10).
extern "C" __global__ void k_abs_int(const int *a32, int *d32, const long long *a64, long long *d64, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = abs(a32[i]);
  d64[i] = llabs(a64[i]);
}

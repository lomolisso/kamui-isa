// selp: select between two values with a predicate (PTX 9.7.6.3).
extern "C" __global__ void k_selp(const int *a,
                                  const int *b,
                                  const unsigned *c,
                                  int *d32,
                                  long long *d64,
                                  int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = (c[i] & 1) ? a[i] : b[i];
  d64[i] = (c[i] & 2) ? (long long)a[i] * 3 : (long long)b[i] << 33;
}

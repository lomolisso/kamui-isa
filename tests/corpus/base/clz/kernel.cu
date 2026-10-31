// clz: count leading zeros, 32 and 64 bits (PTX 9.7.1.15).
extern "C" __global__ void k_clz(const unsigned *a32,
                                 int *d32,
                                 const unsigned long long *a64,
                                 int *d64,
                                 int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned a = a32[i] >> (i & 31);
  d32[i] = __clz(a);
  d64[i] = __clzll(a64[i] >> (i & 63));
}

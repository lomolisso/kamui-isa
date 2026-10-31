// brev: bit reverse, 32 and 64 bits (PTX 9.7.1.18).
extern "C" __global__ void k_brev(const unsigned *a32,
                                  unsigned *d32,
                                  const unsigned long long *a64,
                                  unsigned long long *d64,
                                  int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = __brev(a32[i]);
  d64[i] = __brevll(a64[i]);
}

// popc: population count, 32 and 64 bits (PTX 9.7.1.14).
extern "C" __global__ void k_popc(const unsigned *a32,
                                  int *d32,
                                  const unsigned long long *a64,
                                  int *d64,
                                  int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = __popc(a32[i]);
  d64[i] = __popcll(a64[i]);
}

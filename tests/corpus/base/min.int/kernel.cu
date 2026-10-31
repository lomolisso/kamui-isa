// min.int: integer minimum, signed and unsigned, 32 and 64 bits (PTX 9.7.1.12).
extern "C" __global__ void k_min_int(const int *a32,
                                     const int *b32,
                                     int *d32,
                                     unsigned *du32,
                                     const long long *a64,
                                     const long long *b64,
                                     long long *d64,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = min(a32[i], b32[i]);
  du32[i] = umin((unsigned)a32[i], (unsigned)b32[i]);
  d64[i] = llmin(a64[i], b64[i]);
}

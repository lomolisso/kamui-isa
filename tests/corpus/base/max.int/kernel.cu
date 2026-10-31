// max.int: integer maximum, signed and unsigned, 32 and 64 bits (PTX 9.7.1.13).
extern "C" __global__ void k_max_int(const int *a32,
                                     const int *b32,
                                     int *d32,
                                     unsigned *du32,
                                     const long long *a64,
                                     const long long *b64,
                                     long long *d64,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = max(a32[i], b32[i]);
  du32[i] = umax((unsigned)a32[i], (unsigned)b32[i]);
  d64[i] = llmax(a64[i], b64[i]);
}

// div.int: integer divide, signed and unsigned, 32 and 64 bits; no division by zero (PTX 9.7.1.8).
extern "C" __global__ void k_div_int(const int *a32,
                                     const int *b32,
                                     int *d32,
                                     unsigned *du32,
                                     const long long *a64,
                                     long long *d64,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int b = (i & 1) ? b32[i] : -b32[i];
  d32[i] = a32[i] / b;
  du32[i] = (unsigned)a32[i] / (unsigned)b32[i];
  d64[i] = a64[i] / (long long)b;
}

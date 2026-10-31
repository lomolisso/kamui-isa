// sub.int: integer subtract on 32 and 64 bits (PTX 9.7.1.2).
extern "C" __global__ void k_sub_int(const int *a32,
                                     const int *b32,
                                     int *d32,
                                     const long long *a64,
                                     const long long *b64,
                                     long long *d64,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = a32[i] - b32[i];
  d64[i] = a64[i] - b64[i];
}

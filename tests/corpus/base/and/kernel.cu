// and: bitwise and, or, xor, not on 32 and 64 bits and on predicates (PTX 9.7.8.1 to 9.7.8.4).
extern "C" __global__ void k_and(const unsigned *a32,
                                 const unsigned *b32,
                                 unsigned *d_and,
                                 unsigned *d_or,
                                 unsigned *d_xor,
                                 unsigned *d_not,
                                 const unsigned long long *a64,
                                 const unsigned long long *b64,
                                 unsigned long long *d64,
                                 int *dp,
                                 int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d_and[i] = a32[i] & b32[i];
  d_or[i] = a32[i] | b32[i];
  d_xor[i] = a32[i] ^ b32[i];
  d_not[i] = ~a32[i];
  d64[i] = (a64[i] & ~b64[i]) ^ (a64[i] | (b64[i] >> 7));
  dp[i] = ((a32[i] > 7u) && (b32[i] < 9u)) || ((a32[i] & 1) != (b32[i] & 1));
}

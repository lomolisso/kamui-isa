// add.int: integer add on 32 and 64 bits, wrap-around and .sat (PTX 9.7.1.1).
extern "C" __global__ void k_add_int(const int *a32,
                                     const int *b32,
                                     int *d32,
                                     const long long *a64,
                                     const long long *b64,
                                     long long *d64,
                                     int *dsat,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d32[i] = a32[i] + b32[i];
  d64[i] = a64[i] + b64[i];
  int s;
  asm volatile("add.sat.s32 %0, %1, %2;" : "=r"(s) : "r"(a32[i] * 30000), "r"(b32[i] * 30000));
  dsat[i] = s;
}

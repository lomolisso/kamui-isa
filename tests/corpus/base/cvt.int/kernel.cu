// cvt.int: integer conversions: widen, narrow, sign- and zero-extend, saturate (PTX 9.7.9.21).
extern "C" __global__ void k_cvt_int(const int *a32,
                                     signed char *d8,
                                     unsigned short *d16,
                                     long long *d64,
                                     int *dsat,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int a = a32[i];
  d8[i] = (signed char)a;
  d16[i] = (unsigned short)a;
  d64[i] = (long long)a + (long long)(unsigned)a;
  int s;
  asm volatile("cvt.sat.s8.s32 %0, %1;" : "=r"(s) : "r"(a));
  dsat[i] = s;
}

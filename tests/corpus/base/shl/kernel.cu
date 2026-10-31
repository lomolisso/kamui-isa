// shl: shift left and right, including amounts of at least the register width (PTX 9.7.8.8, 9.7.8.9).
extern "C" __global__ void k_shl(const unsigned *a,
                                 const unsigned *sh,
                                 unsigned *dl32,
                                 unsigned *dru32,
                                 int *drs32,
                                 unsigned long long *dl64,
                                 unsigned *dc,
                                 int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned s = sh[i];
  unsigned l32, ru32;
  int rs32;
  unsigned long long l64;
  asm volatile("shl.b32 %0, %1, %2;" : "=r"(l32) : "r"(a[i]), "r"(s));
  asm volatile("shr.u32 %0, %1, %2;" : "=r"(ru32) : "r"(a[i]), "r"(s));
  asm volatile("shr.s32 %0, %1, %2;" : "=r"(rs32) : "r"((int)a[i]), "r"(s));
  asm volatile("shl.b64 %0, %1, %2;" : "=l"(l64) : "l"((unsigned long long)a[i] << 13), "r"(s * 2));
  dl32[i] = l32;
  dru32[i] = ru32;
  drs32[i] = rs32;
  dl64[i] = l64;
  dc[i] = (a[i] << (s & 31)) ^ ((int)a[i] >> (s & 31)) ^ (a[i] >> (s & 31));
}

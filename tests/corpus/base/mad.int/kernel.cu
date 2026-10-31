// mad.int: integer multiply-add: .lo, .hi, .wide and .hi.sat (PTX 9.7.1.4).
extern "C" __global__ void k_mad_int(const int *a32,
                                     const int *b32,
                                     const int *c32,
                                     int *dlo,
                                     int *dhi,
                                     int *dhisat,
                                     long long *dwide,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int a = a32[i], b = b32[i], c = c32[i];
  dlo[i] = a * b + c;
  int hi, his;
  long long w;
  asm volatile("mad.hi.s32 %0, %1, %2, %3;" : "=r"(hi) : "r"(a), "r"(b), "r"(c));
  asm volatile("mad.hi.sat.s32 %0, %1, %2, %3;" : "=r"(his) : "r"(a), "r"(b), "r"(c));
  asm volatile("mad.wide.s32 %0, %1, %2, %3;" : "=l"(w) : "r"(a), "r"(b), "l"((long long)c << 20));
  dhi[i] = hi;
  dhisat[i] = his;
  dwide[i] = w;
}

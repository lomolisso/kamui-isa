// lop3: arbitrary three-input logic function from an 8-bit lookup table (PTX 9.7.8.6).
extern "C" __global__ void k_lop3(const unsigned *a,
                                  const unsigned *b,
                                  const unsigned *c,
                                  unsigned *d0,
                                  unsigned *d1,
                                  unsigned *d2,
                                  unsigned *d3,
                                  int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r0, r1, r2, r3;
  asm volatile("lop3.b32 %0, %1, %2, %3, 0x96;" : "=r"(r0) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  asm volatile("lop3.b32 %0, %1, %2, %3, 0xe8;" : "=r"(r1) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  asm volatile("lop3.b32 %0, %1, %2, %3, 0xca;" : "=r"(r2) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  asm volatile("lop3.b32 %0, %1, %2, %3, 0x1;" : "=r"(r3) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  d0[i] = r0;
  d1[i] = r1;
  d2[i] = r2;
  d3[i] = r3;
}

// prmt: byte permute, default and the six special modes (PTX 9.7.9.7).
extern "C" __global__ void k_prmt(const unsigned *a,
                                  const unsigned *b,
                                  const unsigned *sel,
                                  unsigned *d,
                                  unsigned *dm,
                                  int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned s = sel[i];
  unsigned r[6];
  d[i] = __byte_perm(a[i], b[i], s);
  asm volatile("prmt.b32.f4e %0, %1, %2, %3;" : "=r"(r[0]) : "r"(a[i]), "r"(b[i]), "r"(s));
  asm volatile("prmt.b32.b4e %0, %1, %2, %3;" : "=r"(r[1]) : "r"(a[i]), "r"(b[i]), "r"(s));
  asm volatile("prmt.b32.rc8 %0, %1, %2, %3;" : "=r"(r[2]) : "r"(a[i]), "r"(b[i]), "r"(s));
  asm volatile("prmt.b32.ecl %0, %1, %2, %3;" : "=r"(r[3]) : "r"(a[i]), "r"(b[i]), "r"(s));
  asm volatile("prmt.b32.ecr %0, %1, %2, %3;" : "=r"(r[4]) : "r"(a[i]), "r"(b[i]), "r"(s));
  asm volatile("prmt.b32.rc16 %0, %1, %2, %3;" : "=r"(r[5]) : "r"(a[i]), "r"(b[i]), "r"(s));
  for (int k = 0; k < 6; k++) dm[6 * i + k] = r[k];
}

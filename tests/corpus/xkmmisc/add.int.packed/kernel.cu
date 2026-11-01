// add.int.packed: packed 16-bit integer add, min and max, with .relu (PTX 9.7.1.1, 9.7.1.12, 9.7.1.13).
extern "C" __global__ void k_add_int_packed(const unsigned *a, const unsigned *b, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r[4];
  asm volatile("add.u16x2 %0, %1, %2;" : "=r"(r[0]) : "r"(a[i]), "r"(b[i]));
  asm volatile("min.s16x2 %0, %1, %2;" : "=r"(r[1]) : "r"(a[i]), "r"(b[i]));
  asm volatile("max.u16x2 %0, %1, %2;" : "=r"(r[2]) : "r"(a[i]), "r"(b[i]));
  asm volatile("max.relu.s16x2 %0, %1, %2;" : "=r"(r[3]) : "r"(a[i]), "r"(b[i]));
  for (int k = 0; k < 4; k++) d[4 * i + k] = r[k];
}

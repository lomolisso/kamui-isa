// mma.int4: warp MMA on s4, m16n8k64, s32 accumulators (PTX 9.7.14.5.14).
extern "C" __global__ void k_mma_int4(const unsigned *a, const unsigned *b, const int *c, int *dd, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int d[4];
  asm volatile("mma.sync.aligned.m16n8k64.row.col.s32.s4.s4.s32 {%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
               : "=r"(d[0]), "=r"(d[1]), "=r"(d[2]), "=r"(d[3])
               : "r"(a[4 * i + 0]), "r"(a[4 * i + 1]), "r"(a[4 * i + 2]), "r"(a[4 * i + 3]), "r"(b[2 * i + 0]), "r"(b[2 * i + 1]), "r"(c[4 * i + 0]), "r"(c[4 * i + 1]), "r"(c[4 * i + 2]), "r"(c[4 * i + 3]));
  for (int k = 0; k < 4; k++) dd[4 * i + k] = d[k];
}

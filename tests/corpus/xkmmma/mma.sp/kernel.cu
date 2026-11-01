// mma.sp: sparse warp MMA on f16, m16n8k32, with 2:4 metadata (PTX 9.7.14.6.3).
extern "C" __global__ void k_mma_sp(const unsigned *a, const unsigned *b, const float *c, float *dd, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float d[4];
  asm volatile("mma.sp.sync.aligned.m16n8k32.row.col.f32.f16.f16.f32 {%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9, %10, %11}, {%12, %13, %14, %15}, %16, 0x0;"
               : "=f"(d[0]), "=f"(d[1]), "=f"(d[2]), "=f"(d[3])
               : "r"(a[4 * i + 0]), "r"(a[4 * i + 1]), "r"(a[4 * i + 2]), "r"(a[4 * i + 3]), "r"(b[4 * i + 0]), "r"(b[4 * i + 1]), "r"(b[4 * i + 2]), "r"(b[4 * i + 3]), "f"(c[4 * i + 0]), "f"(c[4 * i + 1]), "f"(c[4 * i + 2]), "f"(c[4 * i + 3]), "r"(0x44444444u));
  for (int k = 0; k < 4; k++) dd[4 * i + k] = d[k];
}

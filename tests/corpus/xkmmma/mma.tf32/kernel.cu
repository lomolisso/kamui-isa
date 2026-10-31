// mma.tf32: warp MMA on tf32, m16n8k8, f32 accumulators (PTX 9.7.14.5.14).
extern "C" __global__ void k_mma_tf32(const unsigned *a, const unsigned *b, const float *c, float *dd, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float d[4];
  asm volatile("mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32 {%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
               : "=f"(d[0]), "=f"(d[1]), "=f"(d[2]), "=f"(d[3])
               : "r"(a[4 * i + 0]), "r"(a[4 * i + 1]), "r"(a[4 * i + 2]), "r"(a[4 * i + 3]), "r"(b[2 * i + 0]), "r"(b[2 * i + 1]), "f"(c[4 * i + 0]), "f"(c[4 * i + 1]), "f"(c[4 * i + 2]), "f"(c[4 * i + 3]));
  for (int k = 0; k < 4; k++) dd[4 * i + k] = d[k];
}

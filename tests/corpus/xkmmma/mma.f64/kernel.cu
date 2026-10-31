// mma.f64: warp MMA on f64, m8n8k4 (PTX 9.7.14.5.14).
extern "C" __global__ void k_mma_f64(const double *a, const double *b, const double *c, double *dd, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  double d[2];
  asm volatile("mma.sync.aligned.m8n8k4.row.col.f64.f64.f64.f64 {%0, %1}, {%2}, {%3}, {%4, %5};"
               : "=d"(d[0]), "=d"(d[1])
               : "d"(a[1 * i + 0]), "d"(b[1 * i + 0]), "d"(c[2 * i + 0]), "d"(c[2 * i + 1]));
  for (int k = 0; k < 2; k++) dd[2 * i + k] = d[k];
}

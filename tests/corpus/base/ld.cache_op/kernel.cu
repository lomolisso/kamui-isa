// ld.cache_op: loads with cache operators .ca, .cg, .cs, .lu, .cv (PTX 9.7.9.1).
extern "C" __global__ void k_ld_cache_op(const int *a, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int r[5];
  asm volatile("ld.global.ca.u32 %0, [%1];" : "=r"(r[0]) : "l"(&a[i]));
  asm volatile("ld.global.cg.u32 %0, [%1];" : "=r"(r[1]) : "l"(&a[(i + 1) % n]));
  asm volatile("ld.global.cs.u32 %0, [%1];" : "=r"(r[2]) : "l"(&a[(i + 2) % n]));
  asm volatile("ld.global.lu.u32 %0, [%1];" : "=r"(r[3]) : "l"(&a[(i + 3) % n]));
  asm volatile("ld.global.cv.u32 %0, [%1];" : "=r"(r[4]) : "l"(&a[(i + 4) % n]));
  d[i] = r[0] + r[1] + r[2] + r[3] + r[4];
}

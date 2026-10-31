// fp.rounding: the four IEEE rounding modes on add, mul, fma and cvt (PTX 6.5.2, 9.7.3).
extern "C" __global__ void k_fp_rounding(const float *a, const float *b, const float *c, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float x = a[i], y = b[i], z = c[i], r[13];
  asm volatile("add.rn.f32 %0, %1, %2;" : "=f"(r[0]) : "f"(x), "f"(y));
  asm volatile("add.rz.f32 %0, %1, %2;" : "=f"(r[1]) : "f"(x), "f"(y));
  asm volatile("add.rm.f32 %0, %1, %2;" : "=f"(r[2]) : "f"(x), "f"(y));
  asm volatile("add.rp.f32 %0, %1, %2;" : "=f"(r[3]) : "f"(x), "f"(y));
  asm volatile("mul.rz.f32 %0, %1, %2;" : "=f"(r[4]) : "f"(x), "f"(y));
  asm volatile("mul.rm.f32 %0, %1, %2;" : "=f"(r[5]) : "f"(x), "f"(y));
  asm volatile("mul.rp.f32 %0, %1, %2;" : "=f"(r[6]) : "f"(x), "f"(y));
  asm volatile("fma.rz.f32 %0, %1, %2, %3;" : "=f"(r[7]) : "f"(x), "f"(y), "f"(z));
  asm volatile("fma.rm.f32 %0, %1, %2, %3;" : "=f"(r[8]) : "f"(x), "f"(y), "f"(z));
  asm volatile("fma.rp.f32 %0, %1, %2, %3;" : "=f"(r[9]) : "f"(x), "f"(y), "f"(z));
  asm volatile("cvt.rz.f32.f64 %0, %1;" : "=f"(r[10]) : "d"((double)x / 3.0));
  asm volatile("cvt.rm.f32.f64 %0, %1;" : "=f"(r[11]) : "d"((double)x / 3.0));
  asm volatile("cvt.rp.f32.f64 %0, %1;" : "=f"(r[12]) : "d"((double)x / 3.0));
  for (int k = 0; k < 13; k++) d[13 * i + k] = r[k];
}

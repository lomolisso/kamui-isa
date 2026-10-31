// fp.sat: saturate a float result to [0.0, 1.0] (PTX 9.7.3).
extern "C" __global__ void k_fp_sat(const float *a, const float *b, float *d0, float *d1, float *d2, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r0, r1, r2;
  asm volatile("add.sat.f32 %0, %1, %2;" : "=f"(r0) : "f"(a[i]), "f"(b[i]));
  asm volatile("mul.sat.f32 %0, %1, %2;" : "=f"(r1) : "f"(a[i]), "f"(b[i]));
  asm volatile("cvt.sat.f32.f32 %0, %1;" : "=f"(r2) : "f"(a[i]));
  d0[i] = r0;
  d1[i] = r1;
  d2[i] = r2;
}

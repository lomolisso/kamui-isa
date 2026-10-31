// set: compare and write all ones or zero (or 1.0f) to a register, with a boolean combine (PTX 9.7.6.1).
extern "C" __global__ void k_set(const int *a, const int *b, unsigned *d0, unsigned *d1, float *d2, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r0, r1;
  float r2;
  asm volatile("set.lt.u32.s32 %0, %1, %2;" : "=r"(r0) : "r"(a[i]), "r"(b[i]));
  asm volatile("{ .reg .pred p; setp.ne.s32 p, %3, 0; set.ge.and.u32.s32 %0, %1, %2, p; }"
               : "=r"(r1) : "r"(a[i]), "r"(b[i]), "r"(i & 1));
  asm volatile("set.gtu.f32.f32 %0, %1, %2;" : "=f"(r2) : "f"((float)a[i]), "f"((float)b[i]));
  d0[i] = r0;
  d1[i] = r1;
  d2[i] = r2;
}

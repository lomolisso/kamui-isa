// mov: register moves of 32-bit, 64-bit and predicate values (PTX 9.7.9.3).
extern "C" __global__ void k_mov(const unsigned *a,
                                 unsigned *d32,
                                 unsigned long long *d64,
                                 unsigned *df,
                                 int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r32;
  unsigned long long r64;
  float f;
  asm volatile("mov.b32 %0, %1;" : "=r"(r32) : "r"(a[i]));
  asm volatile("mov.b64 %0, %1;" : "=l"(r64) : "l"((unsigned long long)a[i] * 3));
  asm volatile("mov.f32 %0, %1;" : "=f"(f) : "f"(__uint_as_float(a[i])));
  asm volatile("{ .reg .pred p; setp.ne.u32 p, %1, 0; mov.pred p, p; selp.u32 %0, 1, 0, p; }" : "=r"(r32) : "r"(r32 & 1));
  d32[i] = r32;
  d64[i] = r64;
  df[i] = __float_as_uint(f);
}

// testp: test a float for finite, infinite, number, NaN, normal, subnormal (PTX 9.7.3.1).
extern "C" __global__ void k_testp(const float *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned pat[8] = {0x7f800000u, 0xff800000u, 0x7fc00000u, 0x00000001u, 0x80400000u, 0x3f800000u, 0u, 0x80000000u};
  float x = (i & 8) ? __uint_as_float(pat[i & 7]) : a[i];
  unsigned r;
  asm volatile("{ .reg .pred p0, p1, p2, p3, p4, p5;\n\t"
               "testp.finite.f32 p0, %1; testp.infinite.f32 p1, %1; testp.number.f32 p2, %1;\n\t"
               "testp.notanumber.f32 p3, %1; testp.normal.f32 p4, %1; testp.subnormal.f32 p5, %1;\n\t"
               "selp.u32 %0, 1, 0, p0;\n\t"
               "@p1 or.b32 %0, %0, 2; @p2 or.b32 %0, %0, 4; @p3 or.b32 %0, %0, 8;\n\t"
               "@p4 or.b32 %0, %0, 16; @p5 or.b32 %0, %0, 32; }" : "=r"(r) : "f"(x));
  d[i] = r;
}

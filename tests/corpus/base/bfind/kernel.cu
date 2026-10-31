// bfind: find most significant non-sign bit, .u32, .s32 and .shiftamt (PTX 9.7.1.16).
extern "C" __global__ void k_bfind(const unsigned *a32, int *du, int *ds, int *dsh, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned a = a32[i] >> (i & 31);
  int u, s, sh;
  asm volatile("bfind.u32 %0, %1;" : "=r"(u) : "r"(a));
  asm volatile("bfind.s32 %0, %1;" : "=r"(s) : "r"((int)a32[i] >> (i & 31)));
  asm volatile("bfind.shiftamt.u32 %0, %1;" : "=r"(sh) : "r"(a));
  du[i] = u;
  ds[i] = s;
  dsh[i] = sh;
}

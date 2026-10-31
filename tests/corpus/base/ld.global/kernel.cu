// ld.global: global loads of 8-, 16-, 32-, 64-bit and vector types (PTX 9.7.9.8).
extern "C" __global__ void k_ld_global(const unsigned char *b8,
                                       const short *s16,
                                       const int *w32,
                                       const unsigned long long *w64,
                                       const int *v4,
                                       int *d,
                                       int *dv,
                                       int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = (int)b8[i] + (int)s16[i] + (int)w32[i] + (int)(w64[i] >> 17);
  int4 v = ((const int4 *)v4)[i];
  dv[i] = v.x ^ v.y ^ v.z ^ v.w;
}

// wmma.load: warp matrix load, multiply-accumulate and store, m16n16k16 f16 with f32 accumulators (PTX 9.7.14.4.3 to 9.7.14.4.5).
extern "C" __global__ void k_wmma_load(const _Float16 *a, const _Float16 *b, const float *c, float *d) {
  int w = threadIdx.x >> 5;
  int fa[8], fb[8];
  float fc[8], fd[8];
  __hmma_m16n16k16_ld_a(fa, (const int *)(a + 256 * w), 16, 0);
  __hmma_m16n16k16_ld_b(fb, (const int *)(b + 256 * w), 16, 1);
  __hmma_m16n16k16_ld_c_f32(fc, c + 256 * w, 16, 0);
  __hmma_m16n16k16_mma_f32f32(fd, fa, fb, fc, 1, 0);
  __hmma_m16n16k16_st_c_f32(d + 256 * w, fd, 16, 0);
}

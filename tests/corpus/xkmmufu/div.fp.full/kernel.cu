// div.fp.full: full-range approximate division (PTX 9.7.3.8).
extern "C" __global__ void k_div_fp_full(const float *a, const float *b, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float r;
  asm volatile("div.full.f32 %0, %1, %2;" : "=f"(r) : "f"(a[i]), "f"(b[i]));
  d[i] = r;
}

// div.fp.approx: fast approximate division (PTX 9.7.3.8).
extern "C" __global__ void k_div_fp_approx(const float *a, const float *b, float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __fdividef(a[i], b[i]);
}

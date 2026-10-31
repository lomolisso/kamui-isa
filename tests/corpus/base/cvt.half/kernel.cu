// cvt.half: f16 conversions to and from f32 and integers (PTX 9.7.9.21).
extern "C" __global__ void k_cvt_half(const float *f, _Float16 *dh, float *df, int *di, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  _Float16 h = (_Float16)f[i];
  dh[i] = h;
  df[i] = (float)h * 2.0f;
  di[i] = (int)h;
}

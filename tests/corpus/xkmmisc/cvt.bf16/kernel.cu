// cvt.bf16: conversions to and from bf16, with .relu (PTX 9.7.9.21).
extern "C" __global__ void k_cvt_bf16(const float *f, unsigned short *d, unsigned short *d2, float *df, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  __bf16 h = __builtin_bit_cast(__bf16, __nvvm_f2bf16_rn(f[i]));
  d[i] = __builtin_bit_cast(unsigned short, h);
  d2[i] = __builtin_bit_cast(unsigned short, __nvvm_f2bf16_rn_relu(f[i]));
  df[i] = (float)h;
}

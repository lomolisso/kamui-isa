// cvt.fp8: conversions between f32/f16 and the FP8 formats e4m3 and e5m2 (PTX 9.7.9.21).
extern "C" __global__ void k_cvt_fp8(const float *a, const float *b, unsigned short *d8, unsigned *dh, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  short p = __nvvm_ff_to_e4m3x2_rn(a[i], b[i]);
  short q = __nvvm_ff_to_e5m2x2_rn_relu(a[i], b[i]);
  d8[2 * i] = (unsigned short)p;
  d8[2 * i + 1] = (unsigned short)q;
  dh[i] = __builtin_bit_cast(unsigned, __nvvm_e4m3x2_to_f16x2_rn(p));
}

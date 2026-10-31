// fp.cu: does clang contract a*b+c into fma, and what does -fcuda-flush-denormals-to-zero change?
extern "C" __global__ void fp(const float *a, const float *b, const float *c, float *d) {
  int i = threadIdx.x;
  d[i] = a[i] * b[i] + c[i];
  d[i + 32] = a[i] / b[i];
  d[i + 64] = __fsqrt_rn(a[i]);
}

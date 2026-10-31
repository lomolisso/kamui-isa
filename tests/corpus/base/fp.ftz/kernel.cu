// fp.ftz: flush subnormal inputs and results to zero (.ftz) on f32 arithmetic (PTX 9.7.3).
extern "C" __global__ void k_fp_ftz(const float *a,
                                    const float *b,
                                    float *d_add,
                                    float *d_mul,
                                    float *d_fma,
                                    int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d_add[i] = a[i] + b[i];
  d_mul[i] = a[i] * 0.5f;
  d_fma[i] = fmaf(a[i], b[i], a[i]);
}

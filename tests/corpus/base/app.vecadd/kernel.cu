// app.vecadd: vector add, c[i] = a[i] + b[i], over several CTAs with a bounds check.
extern "C" __global__ void k_app_vecadd(const float *a, const float *b, float *c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) c[i] = a[i] + b[i];
}

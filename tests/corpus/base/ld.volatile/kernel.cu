// ld.volatile: volatile loads and stores (PTX 9.7.9.8, 9.7.9.11).
extern "C" __global__ void k_ld_volatile(const int *in, int *buf, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  volatile int *vp = (volatile int *)buf;
  vp[i] = in[i];
  int a = vp[i];
  int b = vp[i];
  d[i] = a + b;
}

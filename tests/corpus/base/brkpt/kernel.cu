// brkpt: breakpoint (PTX 9.7.19.1).
extern "C" __global__ void k_brkpt(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = in[i];
  if (in[i] == 0x7fffffff) __brkpt();
}

// exit: some threads end early with exit; the others still write (PTX 9.7.12.7).
extern "C" __global__ void k_exit(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = -1;
  if (in[i] & 1) __nvvm_exit();
  d[i] = in[i] * 2;
}

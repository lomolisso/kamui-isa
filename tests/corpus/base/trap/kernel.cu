// trap: abort the kernel with trap; the launch must fail (PTX 9.7.19.4).
extern "C" __global__ void k_trap(const int *in, int *d, int n, int at) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = in[i];
  if (i == at) __trap();
}

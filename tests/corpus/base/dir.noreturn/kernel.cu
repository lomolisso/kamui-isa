// dir.noreturn: a device function that never returns, marked .noreturn (PTX 11.4.6).
__device__ __noinline__ __attribute__((noreturn)) void die() { __trap(); }

extern "C" __global__ void k_dir_noreturn(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  if (in[i] == 0x7fffffff) die();
  d[i] = in[i];
}

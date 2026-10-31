// dir.alias: a function alias (PTX 11.2.3).
extern "C" __device__ __noinline__ int scale(int x) { return 3 * x; }
extern "C" __device__ int scale_alias(int x) __attribute__((alias("scale")));

extern "C" __global__ void k_dir_alias(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = scale_alias(in[i]);
}

// dir.weak: a weak device function (PTX 11.6.3).
extern "C" __device__ __noinline__ __attribute__((weak)) int weak_fn(int x) { return x - 5; }

extern "C" __global__ void k_dir_weak(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = weak_fn(in[i]);
}

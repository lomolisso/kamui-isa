// call: direct call of a non-inlined device function with parameters and a result (PTX 9.7.12.5).
__device__ __noinline__ int combine(int a, int b, int c) { return a * c + b; }

extern "C" __global__ void k_call(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = combine(in[i], i, 3);
}

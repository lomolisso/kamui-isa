// app.shfl_reduce: warp sum reduction with shfl.sync.bfly; lane 0 writes the warp total.
extern "C" __global__ void k_app_shfl_reduce(const int *in, int *out, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int v = in[i];
  for (int off = 16; off > 0; off >>= 1) v += __shfl_xor_sync(0xffffffffu, v, off);
  if ((threadIdx.x & 31) == 0) out[i / 32] = v;
}

// bar.warp.sync: warp-level barrier: lanes exchange data through shared memory (PTX 9.7.13.2).
extern "C" __global__ void k_bar_warp_sync(const int *in, int *d) {
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  s[t] = in[i] * 3;
  __syncwarp(0xffffffffu);
  d[i] = s[(t & ~31) | ((t + 11) & 31)];
}

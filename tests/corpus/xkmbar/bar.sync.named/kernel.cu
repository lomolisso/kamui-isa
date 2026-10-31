// bar.sync.named: named barriers 1 and 2 with a thread count, each used by two of the four warps (PTX 9.7.13.1).
extern "C" __global__ void k_bar_sync_named(const int *in, int *d) {
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t, w = t >> 5;
  s[t] = in[i];
  __nvvm_barrier_sync_cnt(1 + (w >> 1), 64);
  d[i] = s[(t & 64) | ((t + 32) & 63)];
}

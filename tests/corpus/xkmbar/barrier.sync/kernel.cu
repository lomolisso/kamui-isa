// barrier.sync: non-aligned barrier: threads of a warp reach it from different branches (PTX 9.7.13.1).
extern "C" __global__ void k_barrier_sync(const int *in, int *d) {
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t & 1) {
    s[t] = in[i] * 3;
    __nvvm_barrier_sync(0);
  } else {
    s[t] = in[i] - 1;
    __nvvm_barrier_sync(0);
  }
  d[i] = s[127 - t];
}

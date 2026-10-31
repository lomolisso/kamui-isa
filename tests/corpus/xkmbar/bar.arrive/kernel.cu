// bar.arrive: producer warp signals with bar.arrive, consumer warp waits with bar.sync (PTX 9.7.13.1).
extern "C" __global__ void k_bar_arrive(const int *in, int *d) {
  __shared__ int s[32];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t < 32) {
    s[t] = in[i] * 5;
    asm volatile("bar.arrive 1, 64;" ::: "memory");
  } else if (t < 64) {
    asm volatile("bar.sync 1, 64;" ::: "memory");
    d[i] = s[63 - t];
  } else {
    d[i] = 0;
  }
}

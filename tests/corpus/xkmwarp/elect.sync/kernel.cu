// elect.sync: elect one leader lane of the warp (PTX 9.7.13.14).
extern "C" __global__ void k_elect_sync(unsigned *dl, unsigned *dp, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned lane, pred;
  unsigned m = (i & 32) ? 0xffffffffu : 0xffffffffu;
  asm volatile("{ .reg .pred p; elect.sync %0|p, %2; selp.u32 %1, 1, 0, p; }" : "=r"(lane), "=r"(pred) : "r"(m));
  dl[i] = lane;
  dp[i] = pred;
}

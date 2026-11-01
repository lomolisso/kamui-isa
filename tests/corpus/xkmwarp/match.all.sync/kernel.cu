// match.all.sync: test whether all lanes hold the same value (PTX 9.7.13.10).
extern "C" __global__ void k_match_all_sync(const unsigned *v, unsigned *dm, int *dp, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int w = i >> 5, p;
  unsigned x = (w & 1) ? 42u : (v[i] & 1);
  dm[i] = __match_all_sync(0xffffffffu, x, &p);
  dp[i] = p;
}

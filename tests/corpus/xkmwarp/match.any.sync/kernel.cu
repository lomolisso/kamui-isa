// match.any.sync: mask of lanes holding the same value, 32- and 64-bit (PTX 9.7.13.10).
extern "C" __global__ void k_match_any_sync(const unsigned *v, unsigned *dv, unsigned *d64, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  dv[i] = __match_any_sync(0xffffffffu, v[i] & 7);
  d64[i] = __match_any_sync(0xffffffffu, (unsigned long long)(v[i] & 3) << 40);
}

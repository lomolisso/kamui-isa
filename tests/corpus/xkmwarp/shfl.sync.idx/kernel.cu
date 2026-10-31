// shfl.sync.idx: warp shuffle .idx with widths 32 and 8, integer and float data (PTX 9.7.9.6).
extern "C" __global__ void k_shfl_sync_idx(const int *v,
                                           const unsigned *src,
                                           int *d,
                                           int *d8,
                                           float *df,
                                           int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned m = 0xffffffffu;
  d[i] = __shfl_sync(m, v[i], src[i] & 31);
  d8[i] = __shfl_sync(m, v[i], src[i] & 31, 8);
  df[i] = __shfl_sync(m, (float)v[i] * 0.5f, src[i] & 31);
}

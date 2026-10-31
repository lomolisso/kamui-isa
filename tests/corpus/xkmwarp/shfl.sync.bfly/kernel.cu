// shfl.sync.bfly: warp shuffle .bfly with widths 32 and 8, integer and float data (PTX 9.7.9.6).
extern "C" __global__ void k_shfl_sync_bfly(const int *v,
                                            const unsigned *src,
                                            int *d,
                                            int *d8,
                                            float *df,
                                            int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned m = 0xffffffffu;
  d[i] = __shfl_xor_sync(m, v[i], 1 << ((i >> 5) % 5));
  d8[i] = __shfl_xor_sync(m, v[i], 1 << ((i >> 5) % 5), 8);
  df[i] = __shfl_xor_sync(m, (float)v[i] * 0.5f, 1 << ((i >> 5) % 5));
}

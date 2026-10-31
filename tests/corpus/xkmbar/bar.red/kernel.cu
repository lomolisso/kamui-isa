// bar.red: barrier with a CTA-wide reduction: popc, and, or (PTX 9.7.13.1).
extern "C" __global__ void k_bar_red(const unsigned *val, int *dc, int *da, int *dor) {
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  int p = (int)(val[i] % 3 == 0);
  dc[i] = __syncthreads_count(p);
  da[i] = __syncthreads_and(blockIdx.x == 0 ? 1 : p);
  dor[i] = __syncthreads_or(blockIdx.x == 0 ? (t == 77) : 0);
}

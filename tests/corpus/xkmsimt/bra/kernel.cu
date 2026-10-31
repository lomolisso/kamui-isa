// bra: divergent branch: lanes take different paths and loop counts (PTX 9.7.12.3).
extern "C" __global__ void k_bra(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int v = in[i], r = 0;
  if (v & 1) {
    for (int k = 0; k < (v & 15); k++) r += k * v;
  } else {
    for (int k = 0; k < ((v >> 4) & 7); k++) r ^= v >> k;
  }
  d[i] = r;
}

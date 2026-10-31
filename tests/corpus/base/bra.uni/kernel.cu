// bra.uni: uniform branch: a loop whose trip count is the same for every thread (PTX 9.7.12.3).
extern "C" __global__ void k_bra_uni(const int *in, int *d, int n, int m) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int r = in[i];
  for (int k = 0; k < m; k++) r = r * 3 + k;
  d[i] = r;
}

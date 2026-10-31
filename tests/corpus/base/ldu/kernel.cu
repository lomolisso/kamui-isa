// ldu: load a value that is uniform across the warp (PTX 9.7.9.10).
extern "C" __global__ void k_ldu(const int *a, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __nvvm_ldu_i(&a[blockIdx.x]) + i;
}

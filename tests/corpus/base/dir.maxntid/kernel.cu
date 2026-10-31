// dir.maxntid: launch bounds: maximum threads per CTA and minimum CTAs per SM (PTX 11.4.2, 11.4.4).
extern "C" __global__ void __launch_bounds__(128, 2) k_dir_maxntid(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = in[i] + 1;
}

// dir.loc: debug information compiled with -g: .file, .loc and .section directives (PTX 11.5.2 to 11.5.4).
extern "C" __global__ void k_dir_loc(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = in[i] * 2 + 1;
}

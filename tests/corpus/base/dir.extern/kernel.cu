// dir.extern: a reference to an external device variable (PTX 11.6.1).
extern __device__ int ext_value;

extern "C" __global__ void k_dir_extern(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = in[i] + ext_value;
}

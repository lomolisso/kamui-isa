// dir.pragma: the "nounroll" pragma from #pragma unroll 1 (PTX 11.4.7).
extern "C" __global__ void k_dir_pragma(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int r = 0;
#pragma unroll 1
  for (int k = 0; k < 8; k++) r += in[(i + k) % n] * k;
  d[i] = r;
}

// ld.global.nc: loads through the read-only data path (__ldg) (PTX 9.7.9.9).
extern "C" __global__ void k_ld_global_nc(const int *a, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __ldg(&a[i]) * 2 + __ldg(&a[(i * 7) % n]);
}

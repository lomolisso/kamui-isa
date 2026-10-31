// sad: sum of absolute differences, signed and unsigned (PTX 9.7.1.7).
extern "C" __global__ void k_sad(const int *a, const int *b, const int *c, unsigned *d, unsigned *du, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __sad(a[i], b[i], (unsigned)c[i]);
  du[i] = __usad((unsigned)a[i], (unsigned)b[i], (unsigned)c[i]);
}

// activemask: mask of the threads active in a divergent branch (PTX 9.7.13.11).
extern "C" __global__ void k_activemask(const unsigned *val, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned am = 0;
  if (val[i] & 1) am = __activemask();
  else if (val[i] & 2) am = __activemask() | 0x80000000u;
  d[i] = am;
}

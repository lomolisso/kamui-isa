// nanosleep: suspend the thread for about the given time (PTX 9.7.19.2).
extern "C" __global__ void k_nanosleep(const int *in, int *d, int *dx, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  long long t0 = clock64();
  __nanosleep(1000);
  long long t1 = clock64();
  d[i] = (t1 > t0) ? 1 : 0;
  dx[i] = in[i] + 1;
}

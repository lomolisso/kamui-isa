// cvta: convert between generic and state-space addresses (PTX 9.7.9.20).
extern "C" __global__ void k_cvta(const int *in, int *d, unsigned *doff) {
  __shared__ int sbuf[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  sbuf[t] = in[i];
  __syncthreads();
  unsigned long long s, s0, g;
  asm volatile("cvta.to.shared.u64 %0, %1;" : "=l"(s) : "l"(&sbuf[(t + 3) & 127]));
  asm volatile("cvta.to.shared.u64 %0, %1;" : "=l"(s0) : "l"(&sbuf[0]));
  asm volatile("cvta.shared.u64 %0, %1;" : "=l"(g) : "l"(s));
  d[i] = *(int *)g;
  doff[i] = (unsigned)(s - s0);
}

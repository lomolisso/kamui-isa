// isspacep: test which state space a generic address points to (PTX 9.7.9.19).
extern "C" __global__ void k_isspacep(const int *in, unsigned *d) {
  __shared__ int sbuf[128];
  int local[4];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  local[t & 3] = t;
  const void *p = (t % 3 == 0) ? (const void *)&sbuf[t] : (t % 3 == 1) ? (const void *)&in[i] : (const void *)&local[t & 3];
  d[i] = __isShared(p) | (__isGlobal(p) << 1) | (__isLocal(p) << 2) | (__isConstant(p) << 3) | (local[t & 3] << 4);
}

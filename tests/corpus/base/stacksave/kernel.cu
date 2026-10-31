// stacksave: dynamic stack allocation: alloca, stacksave and stackrestore (PTX 9.7.17).
extern "C" __global__ void k_stacksave(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned long long sp, p;
  asm volatile("stacksave.u64 %0;" : "=l"(sp));
  asm volatile("{ .reg .u64 l; alloca.u64 l, %1, 8; cvta.local.u64 %0, l; }"
               : "=l"(p) : "l"((unsigned long long)(4 * (in[i] & 15) + 8)));
  int *buf = (int *)p;
  for (int k = 0; k <= (in[i] & 15); k++) buf[k] = k * in[i];
  int s = 0;
  for (int k = 0; k <= (in[i] & 15); k++) s += buf[k];
  asm volatile("stackrestore.u64 %0;" :: "l"(sp));
  d[i] = s;
}

// redux.sync: warp-wide integer reductions: add, min, max, and, or, xor (PTX 9.7.13.12).
extern "C" __global__ void k_redux_sync(const unsigned *v, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned m = 0xffffffffu, x = v[i];
  d[6 * i + 0] = __nvvm_redux_sync_add(x & 0xffff, m);
  d[6 * i + 1] = __nvvm_redux_sync_umin(x, m);
  d[6 * i + 2] = __nvvm_redux_sync_max((int)x, m);
  d[6 * i + 3] = __nvvm_redux_sync_and(x | 0xf0f0f0f0u, m);
  d[6 * i + 4] = __nvvm_redux_sync_or(x & 0x01010101u, m);
  d[6 * i + 5] = __nvvm_redux_sync_xor(x, m);
}

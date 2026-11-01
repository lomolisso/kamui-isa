// setmaxnreg: warpgroup register reallocation hint (PTX 9.7.19.5).
extern "C" __global__ void __launch_bounds__(128, 1) k_setmaxnreg(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("setmaxnreg.inc.sync.aligned.u32 232;" ::: "memory");
  d[i] = a[i] * 2;
  asm volatile("setmaxnreg.dec.sync.aligned.u32 40;" ::: "memory");
}

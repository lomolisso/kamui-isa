// discard: discard L2 lines of a scratch buffer; its contents become undefined (PTX 9.7.9.17).
extern "C" __global__ void k_discard(const unsigned *a, unsigned *scratch, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  scratch[i] = a[i];
  __syncthreads();
  if ((threadIdx.x & 31) == 0) asm volatile("discard.global.L2 [%0], 128;" :: "l"(&scratch[i]) : "memory");
  d[i] = a[i] * 2;
}

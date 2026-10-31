// toy.cu: kamui-isa tool-doc example (our own code).
// One kernel that uses a warp shuffle, a CTA barrier, shared and global
// atomics, and one inline-asm activemask.
#include <cstdint>

extern "C" __global__ void toy(const int *in, int *out, unsigned *mask_out) {
  __shared__ int cta_sum;
  int tid = threadIdx.x;
  if (tid == 0) cta_sum = 0;
  __syncthreads();                                   // bar.sync 0

  int v = in[blockIdx.x * blockDim.x + tid];
  // Butterfly reduction inside one warp: shfl.sync.bfly.b32
  for (int off = 16; off > 0; off >>= 1)
    v += __shfl_xor_sync(0xffffffffu, v, off);

  unsigned am;
  asm volatile("activemask.b32 %0;" : "=r"(am));     // inline asm, kept by volatile
  if ((tid & 31) == 0) {
    atomicAdd(&cta_sum, v);                          // shared-memory atomic
    mask_out[blockIdx.x * (blockDim.x / 32) + tid / 32] = am;
  }
  __syncthreads();
  if (tid == 0) atomicAdd(out, cta_sum);             // global atomic, result unused -> red
}

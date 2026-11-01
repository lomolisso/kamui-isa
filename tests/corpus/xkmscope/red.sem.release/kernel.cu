// red.sem.release: reductions with .release ordering (PTX 9.7.13.6).
extern "C" __global__ void k_red_sem_release(const unsigned *v, unsigned *acc, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("red.release.gpu.global.add.u32 [%0], %1;" :: "l"(&acc[0]), "r"(v[i]) : "memory");
}

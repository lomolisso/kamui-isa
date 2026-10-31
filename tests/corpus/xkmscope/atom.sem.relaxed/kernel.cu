// atom.sem.relaxed: atomic add with .relaxed ordering at GPU scope (PTX 9.7.13.5).
extern "C" __global__ void k_atom_sem_relaxed(const unsigned *v, unsigned *acc, unsigned *old, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned o;
  asm volatile("atom.relaxed.gpu.global.add.u32 %0, [%1], %2;" : "=r"(o) : "l"(&acc[0]), "r"(v[i]) : "memory");
  old[i] = o;
}

// atom.scope.gpu: atomics at GPU scope, the default scope of atomicAdd (PTX 9.7.13.5).
extern "C" __global__ void k_atom_scope_gpu(const unsigned *val,
                                            unsigned *acc,
                                            unsigned *old,
                                            unsigned *acc2,
                                            unsigned *old2,
                                            int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned v = val[i];
  old[i] = atomicAdd(&acc[0], v);
  unsigned o;
  asm volatile("atom.relaxed.gpu.global.add.u32 %0, [%1], %2;" : "=r"(o) : "l"(&acc2[0]), "r"(v) : "memory");
  old2[i] = o;
}

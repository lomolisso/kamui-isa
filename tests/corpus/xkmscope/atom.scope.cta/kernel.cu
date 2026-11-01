// atom.scope.cta: atomics at CTA scope through __nvvm_atom_cta_* (PTX 9.7.13.5).
extern "C" __global__ void k_atom_scope_cta(const unsigned *v, unsigned *acc, unsigned *old, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  old[i] = __nvvm_atom_cta_add_gen_i((int *)&acc[blockIdx.x], (int)v[i]);
}

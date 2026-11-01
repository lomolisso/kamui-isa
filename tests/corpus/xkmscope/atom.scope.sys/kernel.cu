// atom.scope.sys: atomics at system scope through __nvvm_atom_sys_* (PTX 9.7.13.5).
extern "C" __global__ void k_atom_scope_sys(const unsigned *v, unsigned *acc, unsigned *old, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  old[i] = __nvvm_atom_sys_add_gen_i((int *)&acc[0], (int)v[i]);
}

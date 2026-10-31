// atom.global.min: global atomic min: one address shared by all threads and one address per thread (PTX 9.7.13.5).
extern "C" __global__ void k_atom_global_min(const unsigned *val,
                                             unsigned *acc,
                                             unsigned *arr,
                                             unsigned *old_same,
                                             unsigned *old_dist,
                                             long long *acc64,
                                             long long *old64,
                                             int *accs,
                                             int *olds,
                                             int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned v = val[i];
  old_same[i] = atomicMin(&acc[0], v);
  old_dist[i] = atomicMin(&arr[i], v);
  old64[i] = atomicMin(&acc64[0], (long long)v - 0x80000000ll);
  olds[i] = atomicMin(&accs[0], (int)v - 30000);
}

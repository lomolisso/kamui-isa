// atom.global.max: global atomic max: one address shared by all threads and one address per thread (PTX 9.7.13.5).
extern "C" __global__ void k_atom_global_max(const unsigned *val,
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
  old_same[i] = atomicMax(&acc[0], v);
  old_dist[i] = atomicMax(&arr[i], v);
  old64[i] = atomicMax(&acc64[0], (long long)v - 0x80000000ll);
  olds[i] = atomicMax(&accs[0], (int)v - 30000);
}

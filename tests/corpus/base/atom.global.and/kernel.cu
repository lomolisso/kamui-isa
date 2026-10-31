// atom.global.and: global atomic and: one address shared by all threads and one address per thread (PTX 9.7.13.5).
extern "C" __global__ void k_atom_global_and(const unsigned *val,
                                             unsigned *acc,
                                             unsigned *arr,
                                             unsigned *old_same,
                                             unsigned *old_dist,
                                             unsigned long long *acc64,
                                             unsigned long long *old64,
                                             int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned v = val[i];
  old_same[i] = atomicAnd(&acc[0], v);
  old_dist[i] = atomicAnd(&arr[i], v);
  old64[i] = atomicAnd(&acc64[0], (unsigned long long)v * 0x100000001ull);
}

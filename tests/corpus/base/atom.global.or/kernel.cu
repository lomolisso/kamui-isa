// atom.global.or: global atomic or: one address shared by all threads and one address per thread (PTX 9.7.13.5).
extern "C" __global__ void k_atom_global_or(const unsigned *val,
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
  old_same[i] = atomicOr(&acc[0], v);
  old_dist[i] = atomicOr(&arr[i], v);
  old64[i] = atomicOr(&acc64[0], (unsigned long long)v << 7);
}

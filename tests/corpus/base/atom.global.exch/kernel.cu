// atom.global.exch: global atomic exch: one address shared by all threads and one address per thread (PTX 9.7.13.5).
extern "C" __global__ void k_atom_global_exch(const unsigned *val,
                                              unsigned *acc,
                                              unsigned *arr,
                                              unsigned *old_same,
                                              unsigned *old_dist,
                                              unsigned long long *acc64,
                                              unsigned long long *old64,
                                              float *accf,
                                              float *oldf,
                                              int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned v = val[i];
  old_same[i] = atomicExch(&acc[0], v);
  old_dist[i] = atomicExch(&arr[i], v);
  old64[i] = atomicExch(&acc64[0], (unsigned long long)v << 3);
  oldf[i] = atomicExch(&accf[0], (float)v);
}

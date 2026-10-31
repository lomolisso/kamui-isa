// atom.global.add: global atomic add: one address shared by all threads and one address per thread (PTX 9.7.13.5).
extern "C" __global__ void k_atom_global_add(const unsigned *val,
                                             unsigned *acc,
                                             unsigned *arr,
                                             unsigned *old_same,
                                             unsigned *old_dist,
                                             unsigned long long *acc64,
                                             unsigned long long *old64,
                                             float *accf,
                                             float *oldf,
                                             double *accd,
                                             double *oldd,
                                             int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned v = val[i];
  old_same[i] = atomicAdd(&acc[0], v);
  old_dist[i] = atomicAdd(&arr[i], v);
  old64[i] = atomicAdd(&acc64[0], (unsigned long long)v << 20);
  oldf[i] = atomicAdd(&accf[0], (float)v * 0.25f);
  oldd[i] = atomicAdd(&accd[0], (double)v * 0.5);
}

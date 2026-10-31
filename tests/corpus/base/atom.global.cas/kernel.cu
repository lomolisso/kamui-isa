// atom.global.cas: global atomic cas: one address shared by all threads and one address per thread (PTX 9.7.13.5).
extern "C" __global__ void k_atom_global_cas(const unsigned *val,
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
  old_same[i] = atomicCAS(&acc[0], v & 0xff, v);
  old_dist[i] = atomicCAS(&arr[i], v & 0xff, v);
  old64[i] = atomicCAS(&acc64[0], (unsigned long long)(v & 0xff), (unsigned long long)v << 1);
}

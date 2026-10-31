// atom.generic.add: atomics through generic pointers to global or shared memory (PTX 9.7.13.5).
__device__ __noinline__ unsigned bump(unsigned *p, unsigned v) { return atomicAdd(p, v); }

extern "C" __global__ void k_atom_generic_add(const unsigned *val,
                                              unsigned *acc,
                                              unsigned *old,
                                              unsigned *fin) {
  __shared__ unsigned s[1];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t == 0) s[0] = 0;
  __syncthreads();
  unsigned *p = (t & 1) ? &s[0] : &acc[0];
  old[i] = bump(p, val[i]);
  __syncthreads();
  if (t == 0) fin[blockIdx.x] = s[0];
}

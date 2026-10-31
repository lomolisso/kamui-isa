// atom.shared.add: shared-memory atomics: add, min, max, and, or, xor, inc, dec, exch, cas (PTX 9.7.13.5).
extern "C" __global__ void k_atom_shared_add(const unsigned *val,
                                             const unsigned *init,
                                             unsigned *old,
                                             unsigned *fin) {
  __shared__ unsigned s[10];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t < 10) s[t] = init[t];
  __syncthreads();
  unsigned v = val[i];
  old[i] = atomicAdd(&s[0], v);
  atomicMin(&s[1], v); atomicMax(&s[2], v); atomicAnd(&s[3], v | 0xff00u); atomicOr(&s[4], v);
  atomicXor(&s[5], v); atomicInc(&s[6], 1000u); atomicDec(&s[7], 1000u); atomicExch(&s[8], v);
  atomicCAS(&s[9], v & 0xff, v);
  __syncthreads();
  if (t < 10) fin[blockIdx.x * 10 + t] = s[t];
}

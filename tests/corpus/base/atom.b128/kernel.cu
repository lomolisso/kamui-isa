// atom.b128: 128-bit atomic exchange and compare-and-swap (PTX 9.7.13.5).
extern "C" __global__ void k_atom_b128(const unsigned long long *cmp,
                                       const unsigned long long *val,
                                       unsigned long long *cas,
                                       unsigned long long *ex,
                                       unsigned long long *old,
                                       int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned long long lo, hi, lo2, hi2;
  asm volatile("{ .reg .b128 d, b, c;\n\t"
               "mov.b128 b, {%4, %5}; mov.b128 c, {%6, %7};\n\t"
               "atom.global.cas.b128 d, [%8], b, c;\n\t"
               "mov.b128 {%0, %1}, d;\n\t"
               "atom.global.exch.b128 d, [%9], c;\n\t"
               "mov.b128 {%2, %3}, d; }"
               : "=l"(lo), "=l"(hi), "=l"(lo2), "=l"(hi2)
               : "l"(cmp[2 * i]), "l"(cmp[2 * i + 1]), "l"(val[2 * i]), "l"(val[2 * i + 1]), "l"(&cas[2 * i]), "l"(&ex[2 * i])
               : "memory");
  old[4 * i] = lo; old[4 * i + 1] = hi; old[4 * i + 2] = lo2; old[4 * i + 3] = hi2;
}

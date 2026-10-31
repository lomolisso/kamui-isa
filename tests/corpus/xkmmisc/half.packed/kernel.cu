// half.packed: packed f16x2 add, sub, mul and fma (PTX 9.7.4).
typedef _Float16 h2 __attribute__((ext_vector_type(2)));

extern "C" __global__ void k_half_packed(const unsigned *a,
                                         const unsigned *b,
                                         const unsigned *c,
                                         unsigned *dadd,
                                         unsigned *dsub,
                                         unsigned *dmul,
                                         unsigned *dfma,
                                         int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  h2 x = __builtin_bit_cast(h2, a[i]), y = __builtin_bit_cast(h2, b[i]), z = __builtin_bit_cast(h2, c[i]);
  dadd[i] = __builtin_bit_cast(unsigned, x + y);
  dsub[i] = __builtin_bit_cast(unsigned, x - y);
  dmul[i] = __builtin_bit_cast(unsigned, x * y);
  dfma[i] = __builtin_bit_cast(unsigned, __builtin_elementwise_fma(x, y, z));
}

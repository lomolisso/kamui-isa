// st.global: global stores of 8-, 16-, 32-, 64-bit and vector types (PTX 9.7.9.11).
extern "C" __global__ void k_st_global(const int *in,
                                       unsigned char *d8,
                                       short *d16,
                                       unsigned long long *d64,
                                       int *dv,
                                       int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int a = in[i];
  d8[i] = (unsigned char)a;
  d16[i] = (short)a;
  d64[i] = (unsigned long long)a * 0x100000001ull;
  ((int4 *)dv)[i] = make_int4(a, a + 1, a + 2, a + 3);
}

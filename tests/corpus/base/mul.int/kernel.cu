// mul.int: integer multiply: .lo, .hi and .wide forms (PTX 9.7.1.3).
extern "C" __global__ void k_mul_int(const int *a32,
                                     const int *b32,
                                     int *dlo,
                                     int *dhi,
                                     unsigned *duhi,
                                     long long *dwide,
                                     const unsigned long long *ua64,
                                     const unsigned long long *ub64,
                                     unsigned long long *d64hi,
                                     int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int a = a32[i], b = b32[i];
  dlo[i] = a * b;
  dhi[i] = __mulhi(a, b);
  duhi[i] = __umulhi((unsigned)a, (unsigned)b);
  dwide[i] = (long long)a * (long long)b;
  d64hi[i] = __umul64hi(ua64[i], ub64[i]);
}

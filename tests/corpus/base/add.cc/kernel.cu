// add.cc: 128-bit add and subtract through the carry flag: add.cc, addc, sub.cc, subc (PTX 9.7.2).
extern "C" __global__ void k_add_cc(const unsigned long long *alo,
                                    const unsigned long long *ahi,
                                    const unsigned long long *blo,
                                    const unsigned long long *bhi,
                                    unsigned long long *slo,
                                    unsigned long long *shi,
                                    unsigned long long *dlo,
                                    unsigned long long *dhi,
                                    int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned __int128 a = ((unsigned __int128)ahi[i] << 64) | alo[i];
  unsigned __int128 b = ((unsigned __int128)bhi[i] << 64) | blo[i];
  unsigned __int128 s = a + b, d = a - b;
  slo[i] = (unsigned long long)s;
  shi[i] = (unsigned long long)(s >> 64);
  dlo[i] = (unsigned long long)d;
  dhi[i] = (unsigned long long)(d >> 64);
}

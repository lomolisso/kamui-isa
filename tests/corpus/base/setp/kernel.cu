// setp: compare and set a predicate: integer and float, ordered and unordered (PTX 9.7.6.2).
extern "C" __global__ void k_setp(const int *a32,
                                  const int *b32,
                                  const float *fa,
                                  const float *fb,
                                  unsigned *d,
                                  int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int a = a32[i], b = b32[i];
  float x = fa[i], y = fb[i];
  unsigned bits = 0;
  bits |= (a == b) << 0; bits |= (a != b) << 1; bits |= (a < b) << 2; bits |= (a <= b) << 3;
  bits |= ((unsigned)a > (unsigned)b) << 4; bits |= ((unsigned)a >= (unsigned)b) << 5;
  bits |= (x < y) << 6; bits |= (x >= y) << 7; bits |= !(x >= y) << 8; bits |= (x != x) << 9;
  d[i] = bits;
}

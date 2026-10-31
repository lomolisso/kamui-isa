// brx.idx: indirect branch through a jump table built from a dense switch (PTX 9.7.12.4).
extern "C" __global__ void k_brx_idx(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int a = in[i], b = in[(i + 1) % n], r;
  switch ((unsigned)a % 10u) {
    case 0: r = a * b; break;
    case 1: r = a - b * 3; break;
    case 2: r = a ^ (b << 2); break;
    case 3: r = (a | b) + 7; break;
    case 4: r = a / (b | 1); break;
    case 5: r = a % ((b & 255) | 1); break;
    case 6: r = (a & b) * 11; break;
    case 7: r = a + (b >> 3) * 5; break;
    case 8: r = __popc(a) * b; break;
    default: r = __clz(a) - b; break;
  }
  d[i] = r;
}

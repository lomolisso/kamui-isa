// movmatrix: transpose an 8x8 b16 matrix held in warp fragments (PTX 9.7.14.5.17).
extern "C" __global__ void k_movmatrix(const unsigned *in, unsigned *d) {
  int t = threadIdx.x;
  unsigned r;
  asm volatile("movmatrix.sync.aligned.m8n8.trans.b16 %0, %1;" : "=r"(r) : "r"(in[t]));
  d[t] = r;
}

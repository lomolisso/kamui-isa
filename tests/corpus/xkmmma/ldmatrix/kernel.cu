// ldmatrix: load 8x8 matrices of b16 from shared memory into warp fragments, plain and transposed (PTX 9.7.14.5.15).
extern "C" __global__ void k_ldmatrix(const unsigned short *in, unsigned *d) {
  __shared__ unsigned short s[2][256];
  int t = threadIdx.x, w = t >> 5, lane = t & 31;
  for (int k = 0; k < 8; k++) s[w][lane * 8 + k] = in[w * 256 + lane * 8 + k];
  __syncwarp();
  unsigned addr = (unsigned)__cvta_generic_to_shared(&s[w][(lane & 31) * 8]);
  unsigned r[8];
  asm volatile("ldmatrix.sync.aligned.m8n8.x4.shared.b16 {%0, %1, %2, %3}, [%4];"
               : "=r"(r[0]), "=r"(r[1]), "=r"(r[2]), "=r"(r[3]) : "r"(addr));
  asm volatile("ldmatrix.sync.aligned.m8n8.x4.trans.shared.b16 {%0, %1, %2, %3}, [%4];"
               : "=r"(r[4]), "=r"(r[5]), "=r"(r[6]), "=r"(r[7]) : "r"(addr));
  for (int k = 0; k < 8; k++) d[t * 8 + k] = r[k];
}

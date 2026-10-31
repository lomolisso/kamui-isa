// app.atomics: 8 CTAs build a 64-bin histogram and a global maximum with integer atomics.
extern "C" __global__ void k_app_atomics(const unsigned *in, unsigned *bins, unsigned *maxv) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  unsigned v = in[i];
  atomicAdd(&bins[v & 63], 1u);
  atomicMax(&maxv[0], v);
}

// bar.sync: CTA barrier __syncthreads between shared-memory writes and reads (PTX 9.7.13.1).
extern "C" __global__ void k_bar_sync(const int *in, int *d) {
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  s[t] = in[i];
  __syncthreads();
  int a = s[127 - t];
  __syncthreads();
  s[t] = a * 2;
  __syncthreads();
  d[i] = s[(t + 64) & 127] + a;
}

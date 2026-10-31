// ld.shared: shared-memory loads and stores: each thread stores, then reads a neighbour (PTX 9.7.9.8, 9.7.9.11).
extern "C" __global__ void k_ld_shared(const int *in, int *d32, long long *d64) {
  __shared__ int s32v[128];
  __shared__ long long s64v[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  s32v[t] = in[i];
  s64v[t] = (long long)in[i] << 20;
  __syncthreads();
  d32[i] = s32v[(t + 37) & 127];
  d64[i] = s64v[(t + 91) & 127];
}

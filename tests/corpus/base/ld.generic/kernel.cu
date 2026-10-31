// ld.generic: loads and stores through generic pointers to global or shared memory (PTX 9.7.9.8, 9.7.9.11).
__device__ __noinline__ int load_generic(const int *p) { return *p; }
__device__ __noinline__ void store_generic(int *p, int v) { *p = v; }

extern "C" __global__ void k_ld_generic(const int *in, int *tmp, int *d) {
  __shared__ int sbuf[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  sbuf[t] = in[i] + 1;
  __syncthreads();
  int *p = (t & 1) ? &sbuf[(t + 5) & 127] : &tmp[i];
  store_generic(p, in[i] * 3);
  __syncthreads();
  d[i] = load_generic((t & 1) ? &sbuf[(t + 5) & 127] : &tmp[i]);
}

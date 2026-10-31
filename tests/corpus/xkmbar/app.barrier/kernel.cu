// app.barrier: warps exchange data through shared memory around bar.sync: each thread reads the value written by the mirror thread of another warp.
extern "C" __global__ void k_app_barrier(const int *in, int *out) {
  __shared__ int buf[128];
  int t = threadIdx.x;
  buf[t] = in[blockIdx.x * 128 + t] * 2 + t;
  __syncthreads();
  out[blockIdx.x * 128 + t] = buf[127 - t];
}

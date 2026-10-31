// call.indirect: indirect call through a function pointer chosen per thread (PTX 9.7.12.5).
typedef int (*fn_t)(int);
__device__ __noinline__ int f0(int x) { return x + 1; }
__device__ __noinline__ int f1(int x) { return x * 2; }
__device__ __noinline__ int f2(int x) { return -x; }
__device__ __noinline__ fn_t select_fn(int x) { return (x & 3) == 0 ? f0 : (x & 3) == 1 ? f1 : f2; }

extern "C" __global__ void k_call_indirect(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = select_fn(in[i])(in[i]);
}

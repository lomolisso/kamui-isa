// cp.async: asynchronous global-to-shared copies of 4, 8 and 16 bytes with commit and wait (PTX 9.7.9.25.3).
#define AS3(T, p) ((__attribute__((address_space(3))) T *)(p))
#define AS1(T, p) ((__attribute__((address_space(1))) T *)(p))

extern "C" __global__ void k_cp_async(const int *in, int *d) {
  __shared__ __align__(16) int s[128 * 4 + 128 * 2 + 128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  __nvvm_cp_async_cg_shared_global_16(AS3(void, &s[4 * t]), AS1(const void, &in[4 * i]));
  __nvvm_cp_async_ca_shared_global_8(AS3(void, &s[512 + 2 * t]), AS1(const void, &in[1024 + 2 * i]));
  __nvvm_cp_async_ca_shared_global_4(AS3(void, &s[768 + t]), AS1(const void, &in[1536 + i]));
  __nvvm_cp_async_commit_group();
  __nvvm_cp_async_wait_group(0);
  __syncthreads();
  d[i] = s[4 * ((t + 1) & 127)] + s[512 + 2 * ((t + 2) & 127) + 1] + s[768 + ((t + 3) & 127)];
  __nvvm_cp_async_wait_all();
}

// cp.async.bulk.shared_to_global: bulk copy from shared to global memory in a bulk group, after a generic-to-async proxy fence (PTX 9.7.9.25.4.1, 9.7.9.25.6, 9.7.13.4).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }

extern "C" __global__ void k_cp_async_bulk_shared_to_global(const int *in, int *d) {
  __shared__ __align__(128) int s[512];
  int t = threadIdx.x;
  for (int k = 0; k < 4; k++) s[4 * t + k] = in[512 * blockIdx.x + 4 * t + k] * 2;
  asm volatile("fence.proxy.async.shared::cta;" ::: "memory");
  __syncthreads();
  if (t == 0) {
    asm volatile("cp.async.bulk.global.shared::cta.bulk_group [%0], [%1], 2048;" :: "l"(&d[512 * blockIdx.x]), "r"(smem(s)) : "memory");
    asm volatile("cp.async.bulk.commit_group;" ::: "memory");
    asm volatile("cp.async.bulk.wait_group 0;" ::: "memory");
  }
}

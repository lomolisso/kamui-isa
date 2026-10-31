// cp.reduce.async.bulk: bulk reduction (add) from shared memory into global memory (PTX 9.7.9.25.4.2).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }

extern "C" __global__ void k_cp_reduce_async_bulk(const unsigned *v, unsigned *acc) {
  __shared__ __align__(128) unsigned s[512];
  int t = threadIdx.x;
  for (int k = 0; k < 4; k++) s[4 * t + k] = v[512 * blockIdx.x + 4 * t + k];
  asm volatile("fence.proxy.async.shared::cta;" ::: "memory");
  __syncthreads();
  if (t == 0) {
    asm volatile("cp.reduce.async.bulk.global.shared::cta.bulk_group.add.u32 [%0], [%1], 2048;"
                 :: "l"(&acc[0]), "r"(smem(s)) : "memory");
    asm volatile("cp.async.bulk.commit_group;" ::: "memory");
    asm volatile("cp.async.bulk.wait_group.read 0;" ::: "memory");
  }
}

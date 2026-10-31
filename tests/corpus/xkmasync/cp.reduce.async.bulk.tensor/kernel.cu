// cp.reduce.async.bulk.tensor: TMA reduction (add) of a shared-memory box into a u32 tensor (PTX 9.7.9.25.5.3).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
struct __align__(64) TensorMap { unsigned long long w[16]; };

extern "C" __global__ void k_cp_reduce_async_bulk_tensor(unsigned *g, const __grid_constant__ TensorMap tm) {
  __shared__ __align__(128) unsigned s[256];
  int t = threadIdx.x;
  s[2 * t] = 1;
  s[2 * t + 1] = blockIdx.x;
  asm volatile("fence.proxy.async.shared::cta;" ::: "memory");
  __syncthreads();
  if (t == 0) {
    asm volatile("cp.reduce.async.bulk.tensor.2d.global.shared::cta.add.tile.bulk_group [%0, {%1, %2}], [%3];"
                 :: "l"(&tm), "r"(0), "r"(8 * (blockIdx.x & 3)), "r"(smem(s)) : "memory");
    asm volatile("cp.async.bulk.commit_group;" ::: "memory");
    asm volatile("cp.async.bulk.wait_group 0;" ::: "memory");
  }
}

// cp.async.bulk.tensor.store: TMA store of a 32x8 box from shared memory into a 64x32 u32 tensor (PTX 9.7.9.25.5.2).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
struct __align__(64) TensorMap { unsigned long long w[16]; };

extern "C" __global__ void k_cp_async_bulk_tensor_store(unsigned *g, const __grid_constant__ TensorMap tm) {
  __shared__ __align__(128) unsigned s[256];
  int t = threadIdx.x;
  int x = 32 * (blockIdx.x & 1), y = 8 * (blockIdx.x >> 1);
  s[2 * t] = 2 * t + 1000 * blockIdx.x;
  s[2 * t + 1] = 2 * t + 1 + 1000 * blockIdx.x;
  asm volatile("fence.proxy.async.shared::cta;" ::: "memory");
  __syncthreads();
  if (t == 0) {
    asm volatile("cp.async.bulk.tensor.2d.global.shared::cta.bulk_group [%0, {%1, %2}], [%3];"
                 :: "l"(&tm), "r"(x), "r"(y), "r"(smem(s)) : "memory");
    asm volatile("cp.async.bulk.commit_group;" ::: "memory");
    asm volatile("cp.async.bulk.wait_group 0;" ::: "memory");
  }
}

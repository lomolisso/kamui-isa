// cp.async.bulk.tensor.im2col: TMA load in im2col mode from a 3-D tensor (channels, width, images) (PTX 9.7.9.25.5.2).
__device__ __forceinline__ unsigned smem(const void *p) { return (unsigned)__cvta_generic_to_shared(p); }
struct __align__(64) TensorMap { unsigned long long w[16]; };
__device__ __forceinline__ void wait_parity(unsigned bar, unsigned parity) {
  unsigned done = 0;
  while (!done)
    asm volatile("{ .reg .pred p; mbarrier.try_wait.parity.shared::cta.b64 p, [%1], %2; selp.u32 %0, 1, 0, p; }"
                 : "=r"(done) : "r"(bar), "r"(parity) : "memory");
}

extern "C" __global__ void k_cp_async_bulk_tensor_im2col(const unsigned *g,
                                                         const __grid_constant__ TensorMap tm,
                                                         unsigned *d) {
  __shared__ unsigned long long bar;
  __shared__ __align__(128) unsigned s[128];
  int t = threadIdx.x;
  unsigned b = smem(&bar);
  if (t == 0) asm volatile("mbarrier.init.shared::cta.b64 [%0], 1;" :: "r"(b) : "memory");
  __syncthreads();
  if (t == 0) {
    asm volatile("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], 512;" :: "r"(b) : "memory");
    asm volatile("cp.async.bulk.tensor.3d.shared::cluster.global.im2col.mbarrier::complete_tx::bytes"
                 " [%0], [%1, {%2, %3, %4}], [%5], {%6};"
                 :: "r"(smem(s)), "l"(&tm), "r"(0), "r"(0), "r"((int)blockIdx.x), "r"(b), "h"((unsigned short)0) : "memory");
  }
  wait_parity(b, 0);
  d[128 * blockIdx.x + t] = s[t];
}

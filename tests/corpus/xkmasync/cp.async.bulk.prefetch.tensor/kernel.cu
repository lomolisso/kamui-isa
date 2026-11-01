// cp.async.bulk.prefetch.tensor: TMA prefetch of a tensor box into L2 (PTX 9.7.9.25.5.4).
struct __align__(64) TensorMap { unsigned long long w[16]; };

extern "C" __global__ void k_cp_async_bulk_prefetch_tensor(const unsigned *g,
                                                           const __grid_constant__ TensorMap tm,
                                                           unsigned *d) {
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t == 0)
    asm volatile("cp.async.bulk.prefetch.tensor.2d.L2.global.tile [%0, {%1, %2}];" :: "l"(&tm), "r"(0), "r"(8 * blockIdx.x));
  d[i] = g[i] + 1;
}

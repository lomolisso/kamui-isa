// sreg.dynamic_smem_size: shared-memory sizes: %dynamic_smem_size, %total_smem_size (PTX 10.30, 10.32).
extern "C" __global__ void k_sreg_dynamic_smem_size(unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned dyn, tot;
  asm volatile("mov.u32 %0, %%dynamic_smem_size;" : "=r"(dyn));
  asm volatile("mov.u32 %0, %%total_smem_size;" : "=r"(tot));
  d[2 * i] = dyn;
  d[2 * i + 1] = tot;
}

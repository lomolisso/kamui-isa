// sreg.reserved_smem_offset: offsets of the shared memory reserved by the system (PTX 10.29).
extern "C" __global__ void k_sreg_reserved_smem_offset(unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned b, e, c;
  asm volatile("mov.u32 %0, %%reserved_smem_offset_begin;" : "=r"(b));
  asm volatile("mov.u32 %0, %%reserved_smem_offset_end;" : "=r"(e));
  asm volatile("mov.u32 %0, %%reserved_smem_offset_cap;" : "=r"(c));
  d[3 * i] = b; d[3 * i + 1] = e; d[3 * i + 2] = c;
}

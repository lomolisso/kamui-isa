// sreg.current_graph_exec: handle of the CUDA graph that launched the kernel (PTX 10.33).
extern "C" __global__ void k_sreg_current_graph_exec(unsigned long long *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned long long g;
  asm volatile("mov.u64 %0, %%current_graph_exec;" : "=l"(g));
  d[i] = g;
}

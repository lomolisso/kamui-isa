// griddepcontrol: programmatic dependent launch: wait for the previous grid, allow the next one to start (PTX 9.7.13.13).
extern "C" __global__ void k_griddepcontrol(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("griddepcontrol.wait;" ::: "memory");
  d[i] = a[i] + 1;
  asm volatile("griddepcontrol.launch_dependents;" ::: "memory");
}

// membar: memory barriers at CTA, GPU and system level (PTX 9.7.13.4).
extern "C" __global__ void k_membar(const int *val, int *data, int *flag, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  data[i] = val[i];
  __threadfence_block();
  flag[i] = 1;
  __threadfence();
  data[i] += 1;
  __threadfence_system();
  flag[i] += 1;
}

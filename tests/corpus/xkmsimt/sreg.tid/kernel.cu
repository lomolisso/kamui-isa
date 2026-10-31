// sreg.tid: thread, block, CTA and grid ids and sizes in three dimensions: %tid, %ntid, %ctaid, %nctaid (PTX 10.1, 10.2, 10.6, 10.7).
extern "C" __global__ void k_sreg_tid(unsigned *d) {
  int b = (blockIdx.z * gridDim.y + blockIdx.y) * gridDim.x + blockIdx.x;
  int t = (threadIdx.z * blockDim.y + threadIdx.y) * blockDim.x + threadIdx.x;
  int i = b * (blockDim.x * blockDim.y * blockDim.z) + t;
  d[4 * i + 0] = threadIdx.x | (threadIdx.y << 8) | (threadIdx.z << 16);
  d[4 * i + 1] = blockDim.x | (blockDim.y << 8) | (blockDim.z << 16);
  d[4 * i + 2] = blockIdx.x | (blockIdx.y << 8) | (blockIdx.z << 16);
  d[4 * i + 3] = gridDim.x | (gridDim.y << 8) | (gridDim.z << 16);
}

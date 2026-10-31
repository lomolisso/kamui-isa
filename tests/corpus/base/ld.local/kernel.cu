// ld.local: per-thread local memory: a dynamically indexed array (PTX 9.7.9.8, 9.7.9.11).
extern "C" __global__ void k_ld_local(const int *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int buf[64];
  for (int k = 0; k < 64; k++) buf[k] = in[i] * k;
  int idx = (in[i] & 63);
  buf[idx] += 7;
  d[i] = buf[(idx * 5) & 63] + buf[idx];
}

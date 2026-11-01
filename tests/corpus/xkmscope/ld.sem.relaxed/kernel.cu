// ld.sem.relaxed: relaxed atomic loads and stores from C++ atomics (PTX 9.7.9.8, 9.7.9.11).
extern "C" __global__ void k_ld_sem_relaxed(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned x = __atomic_load_n(&a[i], __ATOMIC_RELAXED);
  __atomic_store_n(&d[i], x + 1, __ATOMIC_RELAXED);
}

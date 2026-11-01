// ld.sem.acquire: acquire loads and release stores from C++ atomics (PTX 9.7.9.8, 9.7.9.11).
extern "C" __global__ void k_ld_sem_acquire(const unsigned *a, unsigned *d, unsigned *d2, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  __atomic_store_n(&d[i], a[i] * 2, __ATOMIC_RELEASE);
  d2[i] = __atomic_load_n(&d[i], __ATOMIC_ACQUIRE) + 1;
}

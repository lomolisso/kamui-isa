// atomics.cu: how clang 20 lowers C/C++ atomic orderings and scopes to PTX for sm_90a.
extern "C" __global__ void orderings(int *p, int *out) {
  int a = atomicAdd(p, 1);                                          // CUDA API, result used
  int b = __atomic_fetch_add(p + 1, 1, __ATOMIC_SEQ_CST);
  int c = __atomic_load_n(p + 2, __ATOMIC_ACQUIRE);
  __atomic_store_n(p + 3, a, __ATOMIC_RELEASE);
  int d = __atomic_load_n(p + 4, __ATOMIC_RELAXED);
  int e = __scoped_atomic_fetch_add(p + 5, 1, __ATOMIC_ACQ_REL, __MEMORY_SCOPE_WRKGRP);
  int f = __scoped_atomic_fetch_add(p + 6, 1, __ATOMIC_RELAXED, __MEMORY_SCOPE_SYSTEM);
  int g = 0;
  __atomic_compare_exchange_n(p + 7, &g, 5, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  __threadfence_block();
  __threadfence();
  __threadfence_system();
  out[threadIdx.x] = a + b + c + d + e + f + g;
}

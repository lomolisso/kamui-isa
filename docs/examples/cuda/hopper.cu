// hopper.cu: which Hopper features can clang 20 emit from CUDA C++ builtins?
#include <cstdint>

extern "C" __global__ void hopper_builtins(int *out, int *p) {
  __shared__ long bar;   // 8-byte mbarrier object
  typedef __attribute__((address_space(3))) long smem_i64;
  __shared__ int buf[32];
  unsigned tid = threadIdx.x;

  // mbarrier through clang builtins (sm_80 forms only in clang 20)
  if (tid == 0) __nvvm_mbarrier_init_shared((smem_i64 *)&bar, blockDim.x);
  __syncthreads();
  long st = __nvvm_mbarrier_arrive_shared((smem_i64 *)&bar);
  while (!__nvvm_mbarrier_test_wait_shared((smem_i64 *)&bar, st)) {}

  // cp.async (sm_80) through builtins
  __nvvm_cp_async_ca_shared_global_4((void __attribute__((address_space(3))) *)&buf[tid % 32],
                                     (void __attribute__((address_space(1))) *)&p[tid % 32]);
  __nvvm_cp_async_commit_group();
  __nvvm_cp_async_wait_all();
  __syncthreads();

  // cluster special registers and barrier.cluster (sm_90)
  unsigned rank = __nvvm_read_ptx_sreg_cluster_ctarank();
  __nvvm_barrier_cluster_arrive();
  __nvvm_barrier_cluster_wait();
  __nvvm_fence_sc_cluster();

  // redux.sync (sm_80), scoped atomic builtin (cta scope)
  int r = __nvvm_redux_sync_add(buf[tid % 32], 0xffffffffu);
  __nvvm_atom_cta_add_gen_i(p, 1);
  // C11-style ordered atomics through clang builtins
  int a = __atomic_load_n(p + 1, __ATOMIC_ACQUIRE);
  __atomic_store_n(p + 2, r, __ATOMIC_RELEASE);
  int s = __scoped_atomic_fetch_add(p + 3, 1, __ATOMIC_RELAXED, __MEMORY_SCOPE_WRKGRP);

  out[tid] = r + (int)rank + a + s;
}

// wgmma and setmaxnreg have no clang builtin: inline asm is the only route from CUDA C++.
extern "C" __global__ void hopper_inline_asm(float *out) {
  asm volatile("setmaxnreg.inc.sync.aligned.u32 232;");
  asm volatile("wgmma.fence.sync.aligned;" ::: "memory");
  asm volatile("wgmma.commit_group.sync.aligned;" ::: "memory");
  asm volatile("wgmma.wait_group.sync.aligned 0;" ::: "memory");
  out[threadIdx.x] = 0.0f;
}

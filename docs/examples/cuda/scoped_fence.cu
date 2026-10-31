// scoped_fence.cu: does clang 20 accept __scoped_atomic_thread_fence?
extern "C" __global__ void scoped_fence(int *p) {
  __scoped_atomic_thread_fence(__ATOMIC_ACQ_REL, __MEMORY_SCOPE_WRKGRP);
  __scoped_atomic_thread_fence(__ATOMIC_SEQ_CST, __MEMORY_SCOPE_DEVICE);
  p[threadIdx.x] = 1;
}

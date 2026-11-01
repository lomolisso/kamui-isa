// mbarrier.init: mbarrier life cycle with the sm_80 builtins: init, arrive, test_wait, pending_count, arrive_drop, inval (PTX 9.7.13.15).
#define AS3(T, p) ((__attribute__((address_space(3))) T *)(p))
#define AS1(T, p) ((__attribute__((address_space(1))) T *)(p))

extern "C" __global__ void k_mbarrier_init(const int *in, int *d, unsigned *pc) {
  __shared__ unsigned long long bar;
  __shared__ int s[128];
  int t = threadIdx.x, i = blockIdx.x * 128 + t;
  if (t == 0) __nvvm_mbarrier_init_shared(AS3(long, &bar), 128);
  __syncthreads();
  s[t] = in[i];
  long long st = __nvvm_mbarrier_arrive_shared(AS3(long, &bar));
  pc[i] = __nvvm_mbarrier_pending_count(st);
  while (!__nvvm_mbarrier_test_wait_shared(AS3(long, &bar), st)) {}
  d[i] = s[(t + 1) & 127];
  st = (t < 64) ? __nvvm_mbarrier_arrive_shared(AS3(long, &bar)) : __nvvm_mbarrier_arrive_drop_shared(AS3(long, &bar));
  while (!__nvvm_mbarrier_test_wait_shared(AS3(long, &bar), st)) {}
  __syncthreads();
  if (t == 0) __nvvm_mbarrier_inval_shared(AS3(long, &bar));
}

// its-lock-in-warp: can the 32 lanes of one warp take a spin lock one after another?
//
// mode 0, the classic loop: `while (atomicCAS(lock, 0, 1) != 0) {}` and then the critical section. The lane that
// wins leaves the loop while the other lanes of its warp keep spinning. With one program counter per warp and
// reconvergence at the loop exit (a stack of masks), the winner can never run its release, so the warp hangs.
// With independent scheduling of the lanes, the winner runs ahead, releases, and every lane gets the lock.
// mode 1, the same work with the critical section inside the loop (a flag ends the loop): it works either way.
//
// Spinning is bounded (LIMIT tries) so the kernel always ends. Outputs: order[k] = the k-th lane to get the lock;
// tries[lane] = tries it took, or 0xffffffff if it gave up; cycles[lane] = clock64 cycles from start to the end.
#define LIMIT (1u << 20)

extern "C" __global__ void p_its_lock(unsigned *lock, unsigned *order, unsigned *tries,
                                      unsigned long long *cycles, int mode) {
  unsigned lane = threadIdx.x;
  long long t0 = clock64();
  unsigned n = 0;
  bool got = false;
  if (mode == 0) {
    while (atomicCAS(&lock[0], 0u, 1u) != 0u) {
      if (++n >= LIMIT) break;
    }
    got = n < LIMIT;
    if (got) {
      order[atomicAdd(&lock[1], 1u)] = lane;
      __threadfence();
      atomicExch(&lock[0], 0u);
    }
  } else {
    while (!got && n < LIMIT) {
      n++;
      if (atomicCAS(&lock[0], 0u, 1u) == 0u) {
        order[atomicAdd(&lock[1], 1u)] = lane;
        __threadfence();
        atomicExch(&lock[0], 0u);
        got = true;
      }
    }
  }
  tries[lane] = got ? n : 0xffffffffu;
  cycles[lane] = (unsigned long long)(clock64() - t0);
}

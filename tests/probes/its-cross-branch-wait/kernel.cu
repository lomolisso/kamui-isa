// its-cross-branch-wait: the two sides of a divergent branch wait for each other.
//
// Even lanes (the `if` side) set flag A, then wait for flag B; odd lanes (the `else` side) wait for flag A, then
// set flag B. If a warp runs one side to its end before it starts the other, as a reconvergence stack does, the
// side that runs first waits for a flag that is never set. Only interleaving of the two sides lets both finish.
//
// Spinning is bounded (LIMIT reads) so the kernel always ends. Outputs: res[lane] = reads spent waiting, or
// 0xffffffff if the lane gave up; t[lane] = clock64 when the lane entered its side, relative to the warp's start.
#define LIMIT (1u << 20)

extern "C" __global__ void p_its_cross(unsigned *flags, unsigned *res, unsigned *t) {
  volatile unsigned *f = flags;
  unsigned lane = threadIdx.x;
  long long t0 = clock64();
  unsigned n = 0;
  if ((lane & 1) == 0) {
    t[lane] = (unsigned)(clock64() - t0);
    f[0] = 1;
    while (f[1] == 0 && n < LIMIT) n++;
  } else {
    t[lane] = (unsigned)(clock64() - t0);
    while (f[0] == 0 && n < LIMIT) n++;
    f[1] = 1;
  }
  res[lane] = n < LIMIT ? n : 0xffffffffu;
}

// syncwarp-divergent: one bar.warp.sync with the full mask, reached by the two halves of a warp at two different
// program points (the two sides of a branch).
//
// PTX allows this for sm_70 and later. Each half writes its values to shared memory before its barrier and reads
// the other half's values after it, so the exchange is right only if the barrier really waits for the lanes on
// the other side. The halves do different work first, so the compiler cannot merge the two barriers into one.
// Outputs: got[lane] = the value read from the partner lane (partner * 3 + 5 when correct); mask[lane] = active
// mask right after the barrier.
extern "C" __global__ void p_syncwarp_div(unsigned *got, unsigned *mask, unsigned *sink) {
  __shared__ volatile unsigned s[32];
  volatile unsigned *v = sink;
  unsigned lane = threadIdx.x;
  if (lane < 16) {
    for (unsigned i = 0; i < 3 * lane + 5; i++) v[lane] += i;
    s[lane] = lane * 3 + 5;
    asm volatile("bar.warp.sync -1;" ::: "memory");
    mask[lane] = __activemask();
    got[lane] = s[lane + 16];
  } else {
    for (unsigned i = 0; i < 100 - lane; i++) v[lane] ^= i;
    s[lane] = lane * 3 + 5;
    asm volatile("bar.warp.sync -1;" ::: "memory");
    mask[lane] = __activemask();
    got[lane] = s[lane - 16];
  }
}

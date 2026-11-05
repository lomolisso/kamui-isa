// lat-warp: what warp-wide operations cost, in clock64 cycles (one warp, converged).
//
// Each operation runs REPS times as a dependent chain; cycles[op * 32 + lane] = cycles for the REPS. Operations,
// in order: redux.sync.add (whose result is warp-uniform: it lands in a uniform register), the same sum as a
// five-step shuffle tree, vote.sync.ballot, match.any.sync, activemask, bar.warp.sync, elect.sync, and a read
// of %ctaid.x (a uniform value) through inline asm. The comparison redux against shuffles is the cost of not
// having a uniform result path.
#define REPS 32

#define TIME(body)                                             \
  do {                                                         \
    long long t0 = clock64();                                  \
    _Pragma("unroll") for (int r = 0; r < REPS; r++) { body; } \
    long long t1 = clock64();                                  \
    cycles[k++ * 32 + lane] = (unsigned)(t1 - t0);             \
  } while (0)

extern "C" __global__ void p_lat_warp(unsigned *cycles, unsigned *sink, unsigned seed) {
  unsigned lane = threadIdx.x, k = 0, v = seed + lane;
  TIME({ unsigned x; asm volatile("redux.sync.add.u32 %0, %1, -1;" : "=r"(x) : "r"(v)); v += x; });
  TIME({
    unsigned x = v;
    for (int o = 16; o > 0; o >>= 1) x += __shfl_xor_sync(0xffffffffu, x, o);
    v += x;
  });
  TIME({
    unsigned x;
    asm volatile("{ .reg .pred q; setp.ne.u32 q, %1, 0; vote.sync.ballot.b32 %0, q, -1; }" : "=r"(x) : "r"(v & 1));
    v += x;
  });
  TIME({ unsigned x; asm volatile("match.any.sync.b32 %0, %1, -1;" : "=r"(x) : "r"(v & 3)); v += x; });
  TIME({ unsigned x; asm volatile("activemask.b32 %0;" : "=r"(x)); v += x; });
  TIME({ asm volatile("bar.warp.sync -1;" ::: "memory"); v += 1; });
  TIME({
    unsigned x;
    asm volatile("{ .reg .pred q; elect.sync %0|q, -1; }" : "=r"(x));
    v += x;
  });
  TIME({ unsigned x; asm volatile("mov.u32 %0, %%ctaid.x;" : "=r"(x)); v += x; });
  sink[lane] = v;
}

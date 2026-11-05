// reconv-points: which lanes run together after divergence, and are the two sides of a branch interleaved?
//
// One warp. At each numbered point every lane writes the active mask (`activemask`) and the clock64 cycle count
// since the warp started:
//   0  inside the `if` side of a branch on lane parity       1  inside its `else` side
//   2  right after that if/else (no __syncwarp)                3  after a loop whose trip count is lane % 8
//   4  after a loop that each lane leaves by `break` at its own iteration
//   5  inside a nested branch (lanes < 16, then lane & 2)     6  after the nested branch
//   7  after a divergent loop followed by __syncwarp()      8  after an early `return` of lanes >= 24 (last)
// The sides do real work (loops of lane-dependent length on a volatile value) so the compiler keeps the branches.
// Outputs: mask[point * 32 + lane], t[point * 32 + lane]. Where a lane never reaches a point, the buffer keeps
// its fill value; a reached point always has a nonzero mask.
#define POINT(k)                                     \
  do {                                               \
    mask[(k) * 32 + lane] = __activemask();          \
    t[(k) * 32 + lane] = (unsigned)(clock64() - t0); \
  } while (0)

extern "C" __global__ void p_reconv(unsigned *mask, unsigned *t, unsigned *sink) {
  volatile unsigned *v = sink;
  unsigned lane = threadIdx.x;
  long long t0 = clock64();
  if (lane & 1) {
    POINT(0);
    for (unsigned i = 0; i < 4 + lane; i++) v[lane] += i;
  } else {
    POINT(1);
    for (unsigned i = 0; i < 40 - lane; i++) v[lane] ^= i;
  }
  POINT(2);
  for (unsigned i = 0; i < lane % 8; i++) v[lane] += i * 3;
  POINT(3);
  for (unsigned i = 0; i < 64; i++) {
    v[lane] += i;
    if (i == lane % 5 + 1) break;
  }
  POINT(4);
  if (lane < 16) {
    if (lane & 2) {
      POINT(5);
      v[lane] += 7;
    } else {
      v[lane] -= 3;
    }
  }
  POINT(6);
  for (unsigned i = 0; i < lane; i++) v[lane] += 1;
  __syncwarp();
  POINT(7);
  if (lane >= 24) return;
  v[lane] += 1;
  POINT(8);
}

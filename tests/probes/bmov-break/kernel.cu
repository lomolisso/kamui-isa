// bmov-break: control flow that makes ptxas use BREAK and BMOV, the convergence-barrier instructions not seen in
// any workload, and a check that it runs right.
//
//   nested  a loop nest that each lane leaves from the inner loop at its own iteration (a two-level break)
//   call    a function that is not inlined and has a divergent loop, called from a divergent branch, so the
//           caller's convergence-barrier state must be saved around the call
//   multi   a loop with a `break` and a `return` exit
// Outputs: res[case * 32 + lane] = a value computed on the CPU side of the analysis from the lane number;
// mask[case * 32 + lane] = active mask after the construct.
__device__ __noinline__ unsigned divergent_sum(unsigned lane, volatile unsigned *v) {
  unsigned s = 0;
  for (unsigned i = 0; i < lane % 7 + 1; i++) {
    if ((i ^ lane) & 1) s += v[i & 31];
    else s ^= i;
  }
  return s;
}

extern "C" __global__ void p_bmov_break(unsigned *res, unsigned *mask, unsigned *sink) {
  volatile unsigned *v = sink;
  unsigned lane = threadIdx.x;
  v[lane] = lane;
  __syncwarp();
  // nested
  unsigned found = 0xffffffffu;
  for (unsigned i = 0; i < 8; i++) {
    for (unsigned j = 0; j < 8; j++) {
      if (i * 8 + j == lane * 2 + 1) {
        found = i * 8 + j;
        goto out;
      }
      v[lane] += 1;
    }
  }
out:
  res[0 * 32 + lane] = found;
  mask[0 * 32 + lane] = __activemask();
  // call
  unsigned c = 0;
  if (lane % 3) c = divergent_sum(lane, v) + 1;
  else c = lane;
  res[1 * 32 + lane] = c;
  mask[1 * 32 + lane] = __activemask();
  // multi
  for (unsigned i = 0; i < 40; i++) {
    if (i == lane + 3) break;
    if (lane > 20 && i == lane - 18) {
      res[2 * 32 + lane] = 1000 + i;
      mask[2 * 32 + lane] = __activemask();
      return;
    }
    v[lane] += i;
  }
  res[2 * 32 + lane] = 2000 + lane;
  mask[2 * 32 + lane] = __activemask();
}

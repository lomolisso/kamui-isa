// its-producer-consumer: lane 0 of a warp produces one value for each of lanes 1 to 31, through shared memory.
//
// The consumers are on the `if` side, so a warp that runs that side first (as a reconvergence stack may) spins
// in the consumers forever and never reaches the producer. With independent scheduling of the lanes the producer
// makes progress while the consumers wait.
//
// Spinning is bounded (LIMIT reads). Outputs: got[lane] = the value received (lane * 7 + 1 when it worked) or
// 0xffffffff if the lane gave up; waits[lane] = reads spent waiting.
#define LIMIT (1u << 20)

extern "C" __global__ void p_its_pc(unsigned *got, unsigned *waits) {
  __shared__ unsigned data[32];
  __shared__ volatile unsigned ready[32];
  unsigned lane = threadIdx.x;
  ready[lane] = 0;
  __syncwarp();
  unsigned n = 0;
  if (lane != 0) {
    while (ready[lane] == 0 && n < LIMIT) n++;
    got[lane] = n < LIMIT ? data[lane] : 0xffffffffu;
    waits[lane] = n;
  } else {
    for (unsigned k = 1; k < 32; k++) {
      data[k] = k * 7 + 1;
      __threadfence_block();
      ready[k] = 1;
    }
    got[0] = 0;
    waits[0] = 0;
  }
}

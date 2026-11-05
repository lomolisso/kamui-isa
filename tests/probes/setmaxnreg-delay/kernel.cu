// setmaxnreg-delay: does setmaxnreg.inc wait until another warpgroup of the CTA gives registers back?
//
// One CTA per SM (384 threads, three warpgroups), the producer/consumer split used by Hopper GEMM kernels:
// warpgroup 0 spins for `delay` cycles, then gives registers back with setmaxnreg.dec to 40; warpgroups 1 and 2
// ask for more with setmaxnreg.inc to 232 right away. The CTA starts with the register count ptxas chose for the
// kernel (see its -v output); if that pool is full, the increase can only complete after the decrease. Times are
// clock64 values relative to the CTA's start, written by lane 0 of each warp: t[cta * 12 + warp] = when the warp
// finished its setmaxnreg (decrease or increase), req[cta * 12 + warp] = when it issued it. The entries run with
// delay 0 and delay 200000 cycles.
extern "C" __global__ void __launch_bounds__(384, 1) p_setmaxnreg(unsigned *t, unsigned *req, unsigned *sink,
                                                                  unsigned delay) {
  __shared__ long long start;
  unsigned warp = threadIdx.x / 32, lane = threadIdx.x % 32, cta = blockIdx.x;
  if (threadIdx.x == 0) start = clock64();
  __syncthreads();
  long long t0 = start, t_req, t_done;
  if (warp < 4) {
    long long until = clock64() + delay;
    while (clock64() < until) {
    }
    t_req = clock64();
    asm volatile("setmaxnreg.dec.sync.aligned.u32 40;" ::: "memory");
    t_done = clock64();
  } else {
    t_req = clock64();
    asm volatile("setmaxnreg.inc.sync.aligned.u32 232;" ::: "memory");
    t_done = clock64();
    sink[cta * 384 + threadIdx.x] = (unsigned)t_done ^ lane;
  }
  if (lane == 0) {
    t[cta * 12 + warp] = (unsigned)(t_done - t0);
    req[cta * 12 + warp] = (unsigned)(t_req - t0);
  }
}

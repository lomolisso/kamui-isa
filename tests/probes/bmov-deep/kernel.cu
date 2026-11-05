// bmov-deep: divergent regions nested 24 deep, more than the 16 convergence-barrier registers the H100 has
// (B0 to B15), so ptxas has to move barrier state out of them (BMOV), plus a divergent recursive call. Each level
// branches on one bit of a per-lane value and runs a loop whose trip count differs per lane, so every level is a
// real divergent region. Outputs: res[lane] = the sum the lane computed (checked against the same computation on
// the CPU side of the analysis), mask[d * 32 + lane] = active mask after level d closes (0 if the lane never
// entered it).
__device__ __noinline__ unsigned rec(unsigned x, unsigned d, volatile unsigned *v) {
  if (d == 0) return x;
  unsigned s = 0;
  if ((x >> (d & 7)) & 1) {
    for (unsigned i = 0; i < (x & 3) + 1; i++) s += v[(x + i) & 31];
    s += rec(x * 7 + 1, d - 1, v);
  } else {
    s = rec(x ^ d, d - 1, v);
  }
  return s;
}

extern "C" __global__ void p_bmov_deep(unsigned *res, unsigned *mask, unsigned *sink) {
  volatile unsigned *v = sink;
  unsigned lane = threadIdx.x, x = lane * 2654435761u, s = 0;
  if ((x >> 0) & 1) {
    for (unsigned i = 0; i < ((x >> 3) & 3) + 1; i++) s += v[(lane + i + 0) & 31];
    if ((x >> 1) & 1) {
      for (unsigned i = 0; i < ((x >> 4) & 3) + 1; i++) s += v[(lane + i + 1) & 31];
      if ((x >> 2) & 1) {
        for (unsigned i = 0; i < ((x >> 5) & 3) + 1; i++) s += v[(lane + i + 2) & 31];
        if ((x >> 3) & 1) {
          for (unsigned i = 0; i < ((x >> 6) & 3) + 1; i++) s += v[(lane + i + 3) & 31];
          if ((x >> 4) & 1) {
            for (unsigned i = 0; i < ((x >> 7) & 3) + 1; i++) s += v[(lane + i + 4) & 31];
            if ((x >> 5) & 1) {
              for (unsigned i = 0; i < ((x >> 8) & 3) + 1; i++) s += v[(lane + i + 5) & 31];
              if ((x >> 6) & 1) {
                for (unsigned i = 0; i < ((x >> 9) & 3) + 1; i++) s += v[(lane + i + 6) & 31];
                if ((x >> 7) & 1) {
                  for (unsigned i = 0; i < ((x >> 10) & 3) + 1; i++) s += v[(lane + i + 7) & 31];
                  if ((x >> 8) & 1) {
                    for (unsigned i = 0; i < ((x >> 11) & 3) + 1; i++) s += v[(lane + i + 8) & 31];
                    if ((x >> 9) & 1) {
                      for (unsigned i = 0; i < ((x >> 12) & 3) + 1; i++) s += v[(lane + i + 9) & 31];
                      if ((x >> 10) & 1) {
                        for (unsigned i = 0; i < ((x >> 13) & 3) + 1; i++) s += v[(lane + i + 10) & 31];
                        if ((x >> 11) & 1) {
                          for (unsigned i = 0; i < ((x >> 14) & 3) + 1; i++) s += v[(lane + i + 11) & 31];
                          if ((x >> 12) & 1) {
                            for (unsigned i = 0; i < ((x >> 15) & 3) + 1; i++) s += v[(lane + i + 12) & 31];
                            if ((x >> 13) & 1) {
                              for (unsigned i = 0; i < ((x >> 16) & 3) + 1; i++) s += v[(lane + i + 13) & 31];
                              if ((x >> 14) & 1) {
                                for (unsigned i = 0; i < ((x >> 17) & 3) + 1; i++) s += v[(lane + i + 14) & 31];
                                if ((x >> 15) & 1) {
                                  for (unsigned i = 0; i < ((x >> 18) & 3) + 1; i++) s += v[(lane + i + 15) & 31];
                                  if ((x >> 16) & 1) {
                                    for (unsigned i = 0; i < ((x >> 19) & 3) + 1; i++) s += v[(lane + i + 16) & 31];
                                    if ((x >> 17) & 1) {
                                      for (unsigned i = 0; i < ((x >> 20) & 3) + 1; i++) s += v[(lane + i + 17) & 31];
                                      if ((x >> 18) & 1) {
                                        for (unsigned i = 0; i < ((x >> 21) & 3) + 1; i++) s += v[(lane + i + 18) & 31];
                                        if ((x >> 19) & 1) {
                                          for (unsigned i = 0; i < ((x >> 22) & 3) + 1; i++) s += v[(lane + i + 19) & 31];
                                          if ((x >> 20) & 1) {
                                            for (unsigned i = 0; i < ((x >> 23) & 3) + 1; i++) s += v[(lane + i + 20) & 31];
                                            if ((x >> 21) & 1) {
                                              for (unsigned i = 0; i < ((x >> 24) & 3) + 1; i++) s += v[(lane + i + 21) & 31];
                                              if ((x >> 22) & 1) {
                                                for (unsigned i = 0; i < ((x >> 25) & 3) + 1; i++) s += v[(lane + i + 22) & 31];
                                                if ((x >> 23) & 1) {
                                                  for (unsigned i = 0; i < ((x >> 26) & 3) + 1; i++) s += v[(lane + i + 23) & 31];
                                                  s += rec(x, 6, v);
                                                }
                                                mask[23 * 32 + lane] = __activemask();
                                              }
                                              mask[22 * 32 + lane] = __activemask();
                                            }
                                            mask[21 * 32 + lane] = __activemask();
                                          }
                                          mask[20 * 32 + lane] = __activemask();
                                        }
                                        mask[19 * 32 + lane] = __activemask();
                                      }
                                      mask[18 * 32 + lane] = __activemask();
                                    }
                                    mask[17 * 32 + lane] = __activemask();
                                  }
                                  mask[16 * 32 + lane] = __activemask();
                                }
                                mask[15 * 32 + lane] = __activemask();
                              }
                              mask[14 * 32 + lane] = __activemask();
                            }
                            mask[13 * 32 + lane] = __activemask();
                          }
                          mask[12 * 32 + lane] = __activemask();
                        }
                        mask[11 * 32 + lane] = __activemask();
                      }
                      mask[10 * 32 + lane] = __activemask();
                    }
                    mask[9 * 32 + lane] = __activemask();
                  }
                  mask[8 * 32 + lane] = __activemask();
                }
                mask[7 * 32 + lane] = __activemask();
              }
              mask[6 * 32 + lane] = __activemask();
            }
            mask[5 * 32 + lane] = __activemask();
          }
          mask[4 * 32 + lane] = __activemask();
        }
        mask[3 * 32 + lane] = __activemask();
      }
      mask[2 * 32 + lane] = __activemask();
    }
    mask[1 * 32 + lane] = __activemask();
  }
  mask[0 * 32 + lane] = __activemask();
  res[lane] = s;
}

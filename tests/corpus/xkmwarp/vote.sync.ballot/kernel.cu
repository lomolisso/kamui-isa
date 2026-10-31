// vote.sync.ballot: warp vote .ballot, full and partial member masks (PTX 9.7.13.9).
extern "C" __global__ void k_vote_sync_ballot(const unsigned *val, unsigned *d, unsigned *dh, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int lane = threadIdx.x & 31, w = i >> 5;
  int p = (w == 0) ? 1 : (w == 1) ? 0 : (w == 2) ? (lane != 5) : (int)(val[i] & 1);
  d[i] = (unsigned)__ballot_sync(0xffffffffu, p);
  unsigned h = 0;
  if (lane < 16) h = (unsigned)__ballot_sync(0x0000ffffu, p);
  dh[i] = h;
}

// shf: funnel shift left and right, wrap and clamp modes (PTX 9.7.8.7).
extern "C" __global__ void k_shf(const unsigned *lo,
                                 const unsigned *hi,
                                 const unsigned *sh,
                                 unsigned *dlw,
                                 unsigned *dlc,
                                 unsigned *drw,
                                 unsigned *drc,
                                 int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned s = sh[i];
  dlw[i] = __funnelshift_l(lo[i], hi[i], s);
  dlc[i] = __funnelshift_lc(lo[i], hi[i], s);
  drw[i] = __funnelshift_r(lo[i], hi[i], s);
  drc[i] = __funnelshift_rc(lo[i], hi[i], s);
}

// cvt.fp: integer and float conversions with rounding, and rounding to integral (PTX 9.7.9.21).
extern "C" __global__ void k_cvt_fp(const float *f,
                                    const int *iv,
                                    int *di,
                                    unsigned *du,
                                    float *dfi,
                                    double *dd,
                                    float *dfd,
                                    float *dtr,
                                    float *drn,
                                    float *dfl,
                                    float *dce,
                                    int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float x = f[i];
  double y = (double)x * 1.0000001;
  di[i] = (int)x;
  du[i] = (unsigned)fabsf(x);
  dfi[i] = (float)iv[i];
  dd[i] = y;
  dfd[i] = (float)y;
  dtr[i] = truncf(x);
  drn[i] = rintf(x);
  dfl[i] = floorf(x);
  dce[i] = ceilf(x);
}

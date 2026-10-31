// math.cu: libdevice functions vs fast intrinsics; shows why -nocudalib breaks math.
extern "C" __global__ void mathk(const float *x, float *y) {
  int i = threadIdx.x;
  y[4*i+0] = sinf(x[i]);        // libdevice __nv_sinf (accurate, long sequence)
  y[4*i+1] = __sinf(x[i]);      // sin.approx.f32
  y[4*i+2] = __expf(x[i]);      // ex2.approx based
  y[4*i+3] = tanhf(x[i]);       // libdevice; clang 20 never emits tanh.approx itself
}

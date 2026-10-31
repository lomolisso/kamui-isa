// ld.const: constant memory read with a thread-dependent index (PTX 9.7.9.8).
__constant__ int table[64] = {
  -500, 261, 22, -217, -456, 305, 66, -173, -412, 349, 110, -129, -368, 393, 154, -85,
  -324, 437, 198, -41, -280, 481, 242, 3, -236, -475, 286, 47, -192, -431, 330, 91,
  -148, -387, 374, 135, -104, -343, 418, 179, -60, -299, 462, 223, -16, -255, -494, 267,
  28, -211, -450, 311, 72, -167, -406, 355, 116, -123, -362, 399, 160, -79, -318, 443,
};

extern "C" __global__ void k_ld_const(const unsigned *in, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = table[in[i] & 63] * 3 + table[(in[i] >> 6) & 63];
}

// dump_cubin injects no code into the kernels; the NVBit build helper still expects this file.
#include <stdint.h>

extern "C" __device__ __noinline__ void dump_cubin_unused(int x) { (void)x; }

// tensormap.replace: modify fields of a tensor map held in global memory (PTX 9.7.9.26).
extern "C" __global__ void k_tensormap_replace(unsigned long long *tmb, unsigned long long addr) {
  if (threadIdx.x == 0) {
    asm volatile("tensormap.replace.tile.global_address.global.b1024.b64 [%0], %1;" :: "l"(tmb), "l"(addr) : "memory");
    asm volatile("tensormap.replace.tile.rank.global.b1024.b32 [%0], 1;" :: "l"(tmb) : "memory");
    asm volatile("tensormap.replace.tile.global_dim.global.b1024.b32 [%0], 0, %1;" :: "l"(tmb), "r"(64u) : "memory");
  }
}

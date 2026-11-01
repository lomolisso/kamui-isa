// atom.half: atomic add on f16, f16x2, bf16 and bf16x2 (PTX 9.7.13.5).
extern "C" __global__ void k_atom_half(unsigned short *acch,
                                       unsigned *acch2,
                                       unsigned short *accb,
                                       unsigned *accb2,
                                       unsigned *old,
                                       int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned short o16, b16;
  unsigned o32, b32;
  asm volatile("atom.global.add.noftz.f16 %0, [%1], %2;" : "=h"(o16) : "l"(&acch[0]), "h"((unsigned short)0x3c00) : "memory");
  asm volatile("atom.global.add.noftz.f16x2 %0, [%1], %2;" : "=r"(o32) : "l"(&acch2[0]), "r"(0x38003800u) : "memory");
  asm volatile("atom.global.add.noftz.bf16 %0, [%1], %2;" : "=h"(b16) : "l"(&accb[0]), "h"((unsigned short)0x3f80) : "memory");
  asm volatile("atom.global.add.noftz.bf16x2 %0, [%1], %2;" : "=r"(b32) : "l"(&accb2[0]), "r"(0x3f003f00u) : "memory");
  old[4 * i] = o16; old[4 * i + 1] = o32; old[4 * i + 2] = b16; old[4 * i + 3] = b32;
}

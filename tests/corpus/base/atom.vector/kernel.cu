// atom.vector: vector atomic and reduction adds on f32 pairs and quads (PTX 9.7.13.5, 9.7.13.6).
extern "C" __global__ void k_atom_vector(float *acc, float *racc, float *old, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float o0, o1;
  float x = (float)(i & 7) * 0.25f;
  asm volatile("atom.global.v2.f32.add {%0, %1}, [%2], {%3, %4};" : "=f"(o0), "=f"(o1) : "l"(&acc[2 * (i & 3)]), "f"(x), "f"(1.0f) : "memory");
  asm volatile("red.global.v4.f32.add [%0], {%1, %2, %3, %4};" :: "l"(&racc[0]), "f"(x), "f"(0.5f), "f"(1.0f), "f"(2.0f) : "memory");
  old[2 * i] = o0;
  old[2 * i + 1] = o1;
}

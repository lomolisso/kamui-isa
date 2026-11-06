// addr-windows: where the shared and local windows sit in the generic address space, and what cluster
// addresses look like.
//
// Launched as 4 CTAs of 32 threads in clusters of 2, with 4096 bytes of dynamic shared memory. Thread 0 of each
// CTA writes 64 values to info[cta * 64 + field]; every thread writes the generic address of its own local array
// to local_addr[cta * 32 + lane]. The window bounds come from a binary search with isspacep, which only tests an
// address and never accesses it: starting from an address known to be in the window, it finds the lowest and
// the highest address for which isspacep stays true (assuming the window is one interval, at most 2^44 bytes
// on each side; a bound that reaches 2^44 is reported as that).
// Fields: see the F_* names below.
enum {
  F_GEN_STATIC, F_GEN_DYNAMIC, F_SH_STATIC, F_SH_DYNAMIC, F_RANK, F_CLUSTERID, F_SMID, F_NCTARANK,
  F_MAPA_GEN0, F_MAPA_GEN1, F_MAPA_SH0, F_MAPA_SH1, F_RES_BEGIN, F_RES_END, F_RES_CAP, F_TOTAL_SMEM,
  F_DYN_SMEM, F_AGGR_SMEM, F_P_SH, F_P_SHC, F_P_GLOBAL, F_P_LOCAL, F_P_REMOTE_SH, F_P_REMOTE_SHC,
  F_SH_LO, F_SH_HI, F_SHC_LO, F_SHC_HI, F_LOCAL_LO, F_LOCAL_HI, F_GEN_LOCAL, F_LOCAL_OFF,
  F_P_LOCAL_LOCAL, F_GEN_GLOBAL, F_P_GLOBAL_GLOBAL, F_P_SH_PAST_DYN, F_SH_TO_REMOTE_GEN, F_GLOBAL_LO_HINT,
  F_COUNT
};

#define SPAN (1ull << 44)

__device__ __forceinline__ unsigned isspace_shared(unsigned long long a) {
  unsigned r;
  asm volatile("{ .reg .pred p; isspacep.shared p, %1; selp.u32 %0, 1, 0, p; }" : "=r"(r) : "l"(a));
  return r;
}
__device__ __forceinline__ unsigned isspace_shared_cluster(unsigned long long a) {
  unsigned r;
  asm volatile("{ .reg .pred p; isspacep.shared::cluster p, %1; selp.u32 %0, 1, 0, p; }" : "=r"(r) : "l"(a));
  return r;
}
__device__ __forceinline__ unsigned isspace_local(unsigned long long a) {
  unsigned r;
  asm volatile("{ .reg .pred p; isspacep.local p, %1; selp.u32 %0, 1, 0, p; }" : "=r"(r) : "l"(a));
  return r;
}
__device__ __forceinline__ unsigned isspace_global(unsigned long long a) {
  unsigned r;
  asm volatile("{ .reg .pred p; isspacep.global p, %1; selp.u32 %0, 1, 0, p; }" : "=r"(r) : "l"(a));
  return r;
}

// Lowest (dir 0) or highest (dir 1) address a such that test(x) holds for x between a and p.
template <unsigned (*TEST)(unsigned long long)>
__device__ unsigned long long bound(unsigned long long p, int dir) {
  unsigned long long in = p, out;
  if (dir == 0) {
    out = p > SPAN ? p - SPAN : 0;
    if (TEST(out)) return out;
    while (in - out > 1) {
      unsigned long long mid = out + (in - out) / 2;
      if (TEST(mid)) in = mid; else out = mid;
    }
  } else {
    out = p + SPAN;
    if (TEST(out)) return out;
    while (out - in > 1) {
      unsigned long long mid = in + (out - in) / 2;
      if (TEST(mid)) in = mid; else out = mid;
    }
  }
  return in;
}

__device__ unsigned sreg(int k) {
  unsigned r = 0;
  switch (k) {
    case 0: asm volatile("mov.u32 %0, %%reserved_smem_offset_begin;" : "=r"(r)); break;
    case 1: asm volatile("mov.u32 %0, %%reserved_smem_offset_end;" : "=r"(r)); break;
    case 2: asm volatile("mov.u32 %0, %%reserved_smem_offset_cap;" : "=r"(r)); break;
    case 3: asm volatile("mov.u32 %0, %%total_smem_size;" : "=r"(r)); break;
    case 4: asm volatile("mov.u32 %0, %%dynamic_smem_size;" : "=r"(r)); break;
    case 5: asm volatile("mov.u32 %0, %%aggr_smem_size;" : "=r"(r)); break;
    case 6: asm volatile("mov.u32 %0, %%cluster_ctarank;" : "=r"(r)); break;
    case 7: asm volatile("mov.u32 %0, %%clusterid.x;" : "=r"(r)); break;
    case 8: asm volatile("mov.u32 %0, %%smid;" : "=r"(r)); break;
    case 9: asm volatile("mov.u32 %0, %%cluster_nctarank;" : "=r"(r)); break;
  }
  return r;
}

extern "C" __global__ void p_addr(unsigned long long *info, unsigned long long *local_addr, const unsigned *in,
                                  unsigned idx) {
  __shared__ unsigned s_static[256];
  extern __shared__ unsigned s_dyn[];
  volatile unsigned loc[64];  // indexed by a runtime value, so it lives in local memory
  unsigned lane = threadIdx.x, cta = blockIdx.x;
  loc[idx & 63] = lane;
  s_static[lane] = loc[(idx + lane) & 63];
  s_dyn[lane] = lane;
  unsigned long long gl = (unsigned long long)(const void *)&loc[0];
  local_addr[cta * 32 + lane] = gl;
  asm volatile("barrier.cluster.arrive.release.aligned; barrier.cluster.wait.acquire.aligned;" ::: "memory");
  if (lane == 0) {
    unsigned long long *o = info + cta * 64;
    unsigned long long gs = (unsigned long long)(void *)s_static, gd = (unsigned long long)(void *)s_dyn, t;
    o[F_GEN_STATIC] = gs;
    o[F_GEN_DYNAMIC] = gd;
    asm volatile("cvta.to.shared.u64 %0, %1;" : "=l"(t) : "l"(gs));
    o[F_SH_STATIC] = t;
    unsigned long long sh = t;
    asm volatile("cvta.to.shared.u64 %0, %1;" : "=l"(t) : "l"(gd));
    o[F_SH_DYNAMIC] = t;
    o[F_RANK] = sreg(6);
    o[F_CLUSTERID] = sreg(7);
    o[F_SMID] = sreg(8);
    o[F_NCTARANK] = sreg(9);
    unsigned long long m0, m1;
    asm volatile("mapa.u64 %0, %1, 0;" : "=l"(m0) : "l"(gs));
    asm volatile("mapa.u64 %0, %1, 1;" : "=l"(m1) : "l"(gs));
    o[F_MAPA_GEN0] = m0;
    o[F_MAPA_GEN1] = m1;
    unsigned s32 = (unsigned)sh, c0, c1;
    asm volatile("mapa.shared::cluster.u32 %0, %1, 0;" : "=r"(c0) : "r"(s32));
    asm volatile("mapa.shared::cluster.u32 %0, %1, 1;" : "=r"(c1) : "r"(s32));
    o[F_MAPA_SH0] = c0;
    o[F_MAPA_SH1] = c1;
    for (int k = 0; k < 6; k++) o[F_RES_BEGIN + k] = sreg(k);
    o[F_P_SH] = isspace_shared(gs);
    o[F_P_SHC] = isspace_shared_cluster(gs);
    o[F_P_GLOBAL] = isspace_global(gs);
    o[F_P_LOCAL] = isspace_local(gs);
    unsigned long long remote = o[F_RANK] == 0 ? m1 : m0;
    o[F_P_REMOTE_SH] = isspace_shared(remote);
    o[F_P_REMOTE_SHC] = isspace_shared_cluster(remote);
    o[F_SH_LO] = bound<isspace_shared>(gs, 0);
    o[F_SH_HI] = bound<isspace_shared>(gs, 1);
    o[F_SHC_LO] = bound<isspace_shared_cluster>(gs, 0);
    o[F_SHC_HI] = bound<isspace_shared_cluster>(gs, 1);
    o[F_LOCAL_LO] = bound<isspace_local>(gl, 0);
    o[F_LOCAL_HI] = bound<isspace_local>(gl, 1);
    o[F_GEN_LOCAL] = gl;
    asm volatile("cvta.to.local.u64 %0, %1;" : "=l"(t) : "l"(gl));
    o[F_LOCAL_OFF] = t;
    o[F_P_LOCAL_LOCAL] = isspace_local(gl);
    unsigned long long gg = (unsigned long long)(const void *)in;
    o[F_GEN_GLOBAL] = gg;
    o[F_P_GLOBAL_GLOBAL] = isspace_global(gg);
    o[F_P_SH_PAST_DYN] = isspace_shared(gd + o[F_DYN_SMEM]);
    asm volatile("cvta.shared::cluster.u64 %0, %1;" : "=l"(t) : "l"((unsigned long long)c1));
    o[F_SH_TO_REMOTE_GEN] = t;
    o[F_GLOBAL_LO_HINT] = isspace_global(0x1000ull);
  }
  asm volatile("barrier.cluster.arrive.release.aligned; barrier.cluster.wait.acquire.aligned;" ::: "memory");
}

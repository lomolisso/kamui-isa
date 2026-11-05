// lat-scopes: what memory operations, fences and their scopes cost, in clock64 cycles.
//
// Each thread runs each operation REPS times in a row and writes the cycles the REPS took to
// cycles[op * blockDim.x + tid]; one launch measures all operations, in the order of the OPS list below. Loads
// and atomics form a dependent chain (the next address depends on the previous value through `zero`, a kernel
// argument that is 0), so their cycles are latencies. Stores, reductions and fences do not return a value; their
// cycles are the time to issue REPS of them back to back (for a fence, until it lets the next one start).
// Thread tid uses address buf + tid * stride (stride 0: every thread on the same word, which shows contention).
// The same kernel runs as three entries: 1 thread; one warp on one word; one warp on separate cache lines.
#define REPS 32

// name, then the instruction text. L: load, S: store, A: atomic add, R: reduction, F: fence (no address).
#define OPS(L, S, A, R, F)                                                                                  \
  L(ld_weak, "ld.global.u32")                                                                              \
  L(ld_volatile, "ld.volatile.global.u32")                                                                 \
  L(ld_relaxed_cta, "ld.relaxed.cta.global.u32") L(ld_relaxed_cluster, "ld.relaxed.cluster.global.u32")    \
  L(ld_relaxed_gpu, "ld.relaxed.gpu.global.u32") L(ld_relaxed_sys, "ld.relaxed.sys.global.u32")            \
  L(ld_acquire_cta, "ld.acquire.cta.global.u32") L(ld_acquire_cluster, "ld.acquire.cluster.global.u32")    \
  L(ld_acquire_gpu, "ld.acquire.gpu.global.u32") L(ld_acquire_sys, "ld.acquire.sys.global.u32")            \
  S(st_weak, "st.global.u32")                                                                              \
  S(st_relaxed_cta, "st.relaxed.cta.global.u32") S(st_relaxed_cluster, "st.relaxed.cluster.global.u32")    \
  S(st_relaxed_gpu, "st.relaxed.gpu.global.u32") S(st_relaxed_sys, "st.relaxed.sys.global.u32")            \
  S(st_release_cta, "st.release.cta.global.u32") S(st_release_cluster, "st.release.cluster.global.u32")    \
  S(st_release_gpu, "st.release.gpu.global.u32") S(st_release_sys, "st.release.sys.global.u32")            \
  A(atom_relaxed_cta, "atom.relaxed.cta.global.add.u32")                                                   \
  A(atom_relaxed_cluster, "atom.relaxed.cluster.global.add.u32")                                           \
  A(atom_relaxed_gpu, "atom.relaxed.gpu.global.add.u32") A(atom_relaxed_sys, "atom.relaxed.sys.global.add.u32") \
  A(atom_acq_rel_cta, "atom.acq_rel.cta.global.add.u32")                                                   \
  A(atom_acq_rel_cluster, "atom.acq_rel.cluster.global.add.u32")                                           \
  A(atom_acq_rel_gpu, "atom.acq_rel.gpu.global.add.u32") A(atom_acq_rel_sys, "atom.acq_rel.sys.global.add.u32") \
  R(red_relaxed_gpu, "red.relaxed.gpu.global.add.u32") R(red_release_gpu, "red.release.gpu.global.add.u32") \
  F(fence_acq_rel_cta, "fence.acq_rel.cta") F(fence_acq_rel_cluster, "fence.acq_rel.cluster")              \
  F(fence_acq_rel_gpu, "fence.acq_rel.gpu") F(fence_acq_rel_sys, "fence.acq_rel.sys")                      \
  F(fence_sc_cta, "fence.sc.cta") F(fence_sc_cluster, "fence.sc.cluster")                                  \
  F(fence_sc_gpu, "fence.sc.gpu") F(fence_sc_sys, "fence.sc.sys")                                          \
  F(fence_proxy_async, "fence.proxy.async") F(fence_proxy_async_global, "fence.proxy.async.global")        \
  F(fence_proxy_async_shared_cta, "fence.proxy.async.shared::cta")                                         \
  F(fence_proxy_alias, "fence.proxy.alias")

#define TIME(body)                                  \
  do {                                              \
    long long t0 = clock64();                       \
    _Pragma("unroll") for (int r = 0; r < REPS; r++) { body; } \
    long long t1 = clock64();                       \
    cycles[k++ * nt + tid] = (unsigned)(t1 - t0);   \
  } while (0)

#define DO_L(name, ins) TIME({ unsigned x; asm volatile(ins " %0, [%1];" : "=r"(x) : "l"(p + (v & zero)) : "memory"); v += x; });
#define DO_S(name, ins) TIME({ asm volatile(ins " [%0], %1;" ::"l"(p), "r"(v) : "memory"); });
#define DO_A(name, ins) TIME({ unsigned x; asm volatile(ins " %0, [%1], 1;" : "=r"(x) : "l"(p + (v & zero)) : "memory"); v += x; });
#define DO_R(name, ins) TIME({ asm volatile(ins " [%0], 1;" ::"l"(p) : "memory"); });
#define DO_F(name, ins) TIME({ asm volatile(ins ";" ::: "memory"); });

extern "C" __global__ void p_lat_scopes(unsigned *buf, unsigned *cycles, unsigned *sink, unsigned zero,
                                        unsigned stride) {
  __shared__ unsigned long long bar;
  unsigned tid = threadIdx.x, nt = blockDim.x, k = 0, v = 0;
  unsigned *p = buf + tid * stride;
  OPS(DO_L, DO_S, DO_A, DO_R, DO_F)
  // mbarrier on shared memory: an arrive by every thread completes a phase; then one try_wait on it.
  unsigned b = (unsigned)__cvta_generic_to_shared(&bar);
  if (tid == 0) asm volatile("mbarrier.init.shared::cta.b64 [%0], %1;" ::"r"(b), "r"(nt) : "memory");
  __syncthreads();
  TIME({ asm volatile("{ .reg .b64 st; mbarrier.arrive.shared::cta.b64 st, [%0]; }" ::"r"(b) : "memory"); });
  __syncthreads();
  TIME({
    unsigned ok;
    asm volatile("{ .reg .b64 st; .reg .pred q; mbarrier.arrive.shared::cta.b64 st, [%1];"
                 " mbarrier.try_wait.shared::cta.b64 q, [%1], st; selp.u32 %0, 1, 0, q; }"
                 : "=r"(ok) : "r"(b) : "memory");
    v += ok;
  });
  sink[tid] = v;
}

/*
 * litmus_runner: run one generated litmus kernel many times on the GPU and count its outcomes.
 *
 *     litmus_runner SPEC PTX OUT_JSON [--instances N] [--config plain|stress|shuffle] [--seed S]
 *     litmus_runner --plan SPEC [--config C] [--seed S]   print the placement of one launch, touch no GPU
 *
 * SPEC and PTX come from tools/litmus/to_cuda.py (tests/litmus/h100/<test>/spec.txt and kernel.ptx). The PTX is
 * loaded through the driver JIT, as a PTX loader would. Each launch runs a grid of CLUSTERS clusters of
 * CTAS_PER_CLUSTER CTAs of THREADS threads; the host writes `assign`, which tells every GPU thread whether it is
 * role k of instance i or a stress thread, following the test's placement:
 *
 *   same-cta      the roles of an instance are in different warps of one CTA (groups of NROLES warps)
 *   (in every placement 192 of the 256 threads of a CTA can hold roles; the other 64 are stress threads)
 *   same-cluster  role k is in CTA rank k of a cluster (a random rank permutation with --config shuffle)
 *   diff-cluster  role k is in cluster (c + k * step) mod CLUSTERS, CTA rank k
 *
 * Configurations:
 *   plain    no stress, fixed placement and location layout
 *   stress   threads with no role read and write a 64 MiB scratch buffer while the test runs
 *   shuffle  stress, plus a fresh random placement, location layout and per-thread start delay every launch
 *            (for tests with a cluster barrier, whole warps are shuffled, never single lanes: see make_assign)
 *
 * Every location of every instance has its own 128-byte line. After each launch the host reads each instance's
 * registers, final location values and the SM and cluster of each role, and counts the outcome together with a
 * placement class: same-sm (all roles on one SM), same-cluster (one cluster, more than one SM), diff-cluster.
 *
 * OUT_JSON: {"instances", "launches", "config", "seed", "grid", "seconds", "histogram": [{"values": [...regs,
 * ...final values], "class": "...", "count": n}]}. The values follow the order of `reg` and `gloc` in SPEC.
 * Exit status 0 ok, 3 launch error, 2 setup error, 1 usage. Our own code; CUDA driver API only.
 */
#include <cuda.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define THREADS 256
#define ROLE_THREADS 192 /* per CTA; the other 64 threads (2 warps) are always stress threads */
#define CTAS_PER_CLUSTER 4
#define CLUSTERS 66
#define NCTAS (CLUSTERS * CTAS_PER_CLUSTER)
#define NSLOTS (NCTAS * THREADS)
#define LINE_WORDS 32
#define SCRATCH_WORDS (1u << 24)
#define NONE 0xffffffffu
#define MAXV 24
#define HASH_SIZE 65536

enum placement { SAME_CTA, SAME_CLUSTER, DIFF_CLUSTER };
static const char *CLASSES[] = {"same-sm", "same-cluster", "diff-cluster"};

struct spec {
    int roles, nregs, ngloc, cluster_barrier;
    enum placement place;
};

static int read_spec(const char *path, struct spec *s) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[512], key[64], val[256];
    memset(s, 0, sizeof *s);
    s->place = -1;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || sscanf(line, "%63s %255s", key, val) != 2) continue;
        if (!strcmp(key, "roles")) s->roles = atoi(val);
        else if (!strcmp(key, "nregs")) s->nregs = atoi(val);
        else if (!strcmp(key, "ngloc")) s->ngloc = atoi(val);
        else if (!strcmp(key, "cluster_barrier")) s->cluster_barrier = atoi(val);
        else if (!strcmp(key, "placement"))
            s->place = !strcmp(val, "same-cta") ? SAME_CTA : !strcmp(val, "same-cluster") ? SAME_CLUSTER
                     : !strcmp(val, "diff-cluster") ? DIFF_CLUSTER : -1;
    }
    fclose(f);
    if (s->roles < 1 || s->roles > CTAS_PER_CLUSTER || (int)s->place < 0 || s->nregs + s->ngloc > MAXV) return -1;
    return 0;
}

/* xorshift64*: a small seeded generator, so a run can be repeated exactly. */
static uint64_t rng_state;
static uint32_t rnd(void) {
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    return (uint32_t)((rng_state * 2685821657736338717ull) >> 32);
}
static void shuffle(unsigned *a, unsigned n) {
    for (unsigned i = n - 1; i > 0; i--) {
        unsigned j = rnd() % (i + 1), t = a[i];
        a[i] = a[j];
        a[j] = t;
    }
}
static void identity(unsigned *a, unsigned n) {
    for (unsigned i = 0; i < n; i++) a[i] = i;
}
#define PACK(inst, role, lslot) (((inst) << 11) | ((lslot) << 3) | (role))

/* Fill assign for one launch; return the number of instances. */
static unsigned make_assign(const struct spec *s, int random, unsigned *assign) {
    unsigned n = s->roles, inst = 0;
    for (unsigned i = 0; i < NSLOTS; i++) assign[i] = NONE;
    if (s->place == SAME_CTA) {
        unsigned warps = THREADS / 32, groups = (ROLE_THREADS / 32) / n, wperm[THREADS / 32];
        unsigned lperm[CTAS_PER_CLUSTER][32];
        for (unsigned c = 0; c < NCTAS; c++) {
            identity(wperm, warps);
            if (random) shuffle(wperm, warps);
            for (unsigned g = 0; g < groups; g++) {
                for (unsigned k = 0; k < n; k++) {
                    identity(lperm[k], 32);
                    if (random) shuffle(lperm[k], 32);
                }
                for (unsigned l = 0; l < 32; l++, inst++)
                    for (unsigned k = 0; k < n; k++)
                        assign[c * THREADS + wperm[g * n + k] * 32 + lperm[k][l]] = PACK(inst, k, g * 32 + l);
            }
        }
        return inst;
    }
    unsigned rank[CTAS_PER_CLUSTER], step = 1;
    identity(rank, CTAS_PER_CLUSTER);
    if (random) shuffle(rank, CTAS_PER_CLUSTER);
    if (s->place == DIFF_CLUSTER && random) {
        /* a step that sends the roles of one instance to n different clusters */
        for (;;) {
            step = 1 + rnd() % (CLUSTERS - 1);
            int ok = 1;
            for (unsigned k = 1; k < n && ok; k++)
                for (unsigned j = 0; j < k && ok; j++)
                    ok = (k * step) % CLUSTERS != (j * step) % CLUSTERS;
            if (ok) break;
        }
    }
    static unsigned sperm[CTAS_PER_CLUSTER][THREADS];
    for (unsigned c = 0; c < CLUSTERS; c++) {
        for (unsigned k = 0; k < n; k++) {
            identity(sperm[k], THREADS);
            if (random && s->cluster_barrier) {
                /* Shuffle whole warps only: barrier.cluster.arrive.relaxed compiles to WARPSYNC.ALL; UCGABAR_ARV,
                 * so a warp whose lanes reach different barrier.cluster instructions deadlocks. */
                unsigned w[THREADS / 32];
                identity(w, THREADS / 32);
                shuffle(w, THREADS / 32);
                for (unsigned t = 0; t < THREADS; t++) sperm[k][t] = w[t / 32] * 32 + t % 32;
            } else if (random) {
                shuffle(sperm[k], THREADS);
            }
        }
        for (unsigned t = 0; t < ROLE_THREADS; t++, inst++)
            for (unsigned k = 0; k < n; k++) {
                unsigned cl = s->place == SAME_CLUSTER ? c : (c + k * step) % CLUSTERS;
                unsigned cta = cl * CTAS_PER_CLUSTER + rank[k];
                assign[cta * THREADS + sperm[k][t]] = PACK(inst, k, sperm[k][t] & 255);
            }
    }
    return inst;
}

struct bucket {
    int used, cls;
    unsigned v[MAXV];
    unsigned long long count;
};
static struct bucket table[HASH_SIZE];

static void count(const unsigned *v, int nv, int cls) {
    uint64_t h = 1469598103934665603ull ^ (uint64_t)cls;
    for (int i = 0; i < nv; i++) h = (h ^ v[i]) * 1099511628211ull;
    for (uint64_t i = h % HASH_SIZE;; i = (i + 1) % HASH_SIZE) {
        struct bucket *b = &table[i];
        if (!b->used) {
            b->used = 1, b->cls = cls, b->count = 1;
            memcpy(b->v, v, nv * sizeof *v);
            return;
        }
        if (b->cls == cls && !memcmp(b->v, v, nv * sizeof *v)) {
            b->count++;
            return;
        }
    }
}

#define CHECK(x)                                                                    \
    do {                                                                            \
        CUresult r_ = (x);                                                          \
        if (r_ != CUDA_SUCCESS) {                                                   \
            const char *n_ = "?";                                                   \
            cuGetErrorName(r_, &n_);                                                \
            fprintf(stderr, "%s:%d: %s failed: %s\n", __FILE__, __LINE__, #x, n_); \
            return launch_phase ? 3 : 2;                                            \
        }                                                                           \
    } while (0)

static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = malloc(n + 1);
    if (b && fread(b, 1, n, f) != (size_t)n) n = 0;
    if (b) b[n] = 0;
    fclose(f);
    return b;
}

int main(int argc, char **argv) {
    const char *spec_path = NULL, *ptx_path = NULL, *out_path = NULL, *config = "plain";
    unsigned long long want = 1000000, seed = 1;
    int plan = 0, launch_phase = 0, pos = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--instances") && i + 1 < argc) want = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--config") && i + 1 < argc) config = argv[++i];
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--plan")) plan = 1;
        else if (pos == 0) spec_path = argv[i], pos++;
        else if (pos == 1) ptx_path = argv[i], pos++;
        else if (pos == 2) out_path = argv[i], pos++;
    }
    int stress = !strcmp(config, "stress") || !strcmp(config, "shuffle"), random = !strcmp(config, "shuffle");
    if (!spec_path || (!plan && !out_path) || (strcmp(config, "plain") && !stress)) {
        fprintf(stderr, "usage: litmus_runner SPEC PTX OUT_JSON [--instances N] [--config plain|stress|shuffle]"
                        " [--seed S]\n       litmus_runner --plan SPEC [--config C] [--seed S]\n");
        return 1;
    }
    struct spec s;
    if (read_spec(spec_path, &s)) {
        fprintf(stderr, "%s: bad spec\n", spec_path);
        return 2;
    }
    rng_state = seed * 0x9E3779B97F4A7C15ull + 1;
    static unsigned assign[NSLOTS];
    unsigned per_launch = make_assign(&s, random, assign);
    if (plan) {
        unsigned used = 0;
        for (unsigned i = 0; i < NSLOTS; i++) used += assign[i] != NONE;
        printf("placement %d roles %d instances/launch %u role-threads %u stress-threads %u\n", s.place, s.roles,
               per_launch, used, NSLOTS - used);
        for (unsigned i = 0; i < NSLOTS && i < 2 * THREADS; i += 32)
            printf("slot %u: %08x\n", i, assign[i]);
        return 0;
    }
    char *ptx = slurp(ptx_path);
    if (!ptx) {
        fprintf(stderr, "%s: cannot read\n", ptx_path);
        return 2;
    }
    int nv = s.nregs + s.ngloc, ngl = s.ngloc ? s.ngloc : 1, nrg = s.nregs ? s.nregs : 1;
    size_t mem_words = (size_t)per_launch * ngl * LINE_WORDS;
    CUdevice dev;
    CUcontext ctx;
    CUmodule mod;
    CUfunction fn;
    CHECK(cuInit(0));
    CHECK(cuDeviceGet(&dev, 0));
    CHECK(cuDevicePrimaryCtxRetain(&ctx, dev));
    CHECK(cuCtxSetCurrent(ctx));
    char log[8192] = {0};
    CUjit_option jo[] = {CU_JIT_ERROR_LOG_BUFFER, CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES};
    void *jv[] = {log, (void *)(uintptr_t)sizeof log};
    if (cuModuleLoadDataEx(&mod, ptx, 2, jo, jv) != CUDA_SUCCESS) {
        fprintf(stderr, "JIT failed: %s\n", log);
        return 2;
    }
    CHECK(cuModuleGetFunction(&fn, mod, "litmus"));
    CUdeviceptr d_mem, d_res, d_place, d_assign, d_locoff, d_scratch;
    CHECK(cuMemAlloc(&d_mem, mem_words * 4));
    CHECK(cuMemAlloc(&d_res, (size_t)per_launch * nrg * 4));
    CHECK(cuMemAlloc(&d_place, (size_t)per_launch * s.roles * 4));
    CHECK(cuMemAlloc(&d_assign, sizeof assign));
    CHECK(cuMemAlloc(&d_locoff, (size_t)per_launch * ngl * 4));
    CHECK(cuMemAlloc(&d_scratch, (size_t)SCRATCH_WORDS * 4));
    CHECK(cuMemsetD32(d_scratch, 0, SCRATCH_WORDS));
    unsigned *locoff = malloc((size_t)per_launch * ngl * 4), *lines = malloc((size_t)per_launch * ngl * 4);
    unsigned *res = malloc((size_t)per_launch * nrg * 4), *place = malloc((size_t)per_launch * s.roles * 4);
    unsigned *mem = malloc(mem_words * 4);
    if (!locoff || !lines || !res || !place || !mem) return 2;
    unsigned nlines = per_launch * ngl;
    identity(lines, nlines);
    for (unsigned i = 0; i < nlines; i++) locoff[i] = lines[i] * LINE_WORDS;
    CHECK(cuMemcpyHtoD(d_assign, assign, sizeof assign));
    CHECK(cuMemcpyHtoD(d_locoff, locoff, (size_t)nlines * 4));

    unsigned scratch_mask = SCRATCH_WORDS - 1, stress_iters = stress ? 512 : 0, delay_mask = random ? 255 : 0;
    void *args[] = {&d_mem, &d_res, &d_place, &d_assign, &d_locoff, &d_scratch, &scratch_mask, &stress_iters,
                    &delay_mask};
    CUlaunchAttribute attr = {.id = CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION};
    attr.value.clusterDim.x = CTAS_PER_CLUSTER, attr.value.clusterDim.y = 1, attr.value.clusterDim.z = 1;
    CUlaunchConfig cfg = {.gridDimX = NCTAS, .gridDimY = 1, .gridDimZ = 1, .blockDimX = THREADS, .blockDimY = 1,
                          .blockDimZ = 1, .sharedMemBytes = 0, .hStream = 0, .attrs = &attr, .numAttrs = 1};
    unsigned long long done = 0, launches = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    launch_phase = 1;
    while (done < want) {
        if (random && launches > 0) {
            make_assign(&s, 1, assign);
            shuffle(lines, nlines);
            for (unsigned i = 0; i < nlines; i++) locoff[i] = lines[i] * LINE_WORDS;
            CHECK(cuMemcpyHtoD(d_assign, assign, sizeof assign));
            CHECK(cuMemcpyHtoD(d_locoff, locoff, (size_t)nlines * 4));
        }
        CHECK(cuMemsetD32(d_mem, 0, mem_words));
        CHECK(cuMemsetD32(d_res, 0, (size_t)per_launch * nrg));
        CHECK(cuLaunchKernelEx(&cfg, fn, args, NULL));
        CHECK(cuCtxSynchronize());
        CHECK(cuMemcpyDtoH(res, d_res, (size_t)per_launch * nrg * 4));
        CHECK(cuMemcpyDtoH(place, d_place, (size_t)per_launch * s.roles * 4));
        CHECK(cuMemcpyDtoH(mem, d_mem, mem_words * 4));
        for (unsigned i = 0; i < per_launch; i++) {
            unsigned v[MAXV];
            for (int r = 0; r < s.nregs; r++) v[r] = res[(size_t)i * nrg + r];
            for (int g = 0; g < s.ngloc; g++) v[s.nregs + g] = mem[locoff[(size_t)i * ngl + g]];
            int same_sm = 1, same_cl = 1;
            for (int k = 1; k < s.roles; k++) {
                unsigned a = place[(size_t)i * s.roles], b = place[(size_t)i * s.roles + k];
                same_sm &= a == b;
                same_cl &= (a >> 8) == (b >> 8);
            }
            count(v, nv, same_sm ? 0 : same_cl ? 1 : 2);
        }
        done += per_launch;
        launches++;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    FILE *o = fopen(out_path, "w");
    if (!o) return 2;
    fprintf(o, "{\"instances\": %llu, \"launches\": %llu, \"config\": \"%s\", \"seed\": %llu, ", done, launches,
            config, seed);
    fprintf(o, "\"grid\": {\"clusters\": %d, \"ctas_per_cluster\": %d, \"threads\": %d, \"instances_per_launch\": %u}, ",
            CLUSTERS, CTAS_PER_CLUSTER, THREADS, per_launch);
    fprintf(o, "\"seconds\": %.3f, \"histogram\": [",
            (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9);
    int first = 1;
    for (int i = 0; i < HASH_SIZE; i++) {
        if (!table[i].used) continue;
        fprintf(o, "%s\n  {\"values\": [", first ? "" : ",");
        for (int k = 0; k < nv; k++) fprintf(o, "%s%u", k ? ", " : "", table[i].v[k]);
        fprintf(o, "], \"class\": \"%s\", \"count\": %llu}", CLASSES[table[i].cls], table[i].count);
        first = 0;
    }
    fprintf(o, "\n]}\n");
    fclose(o);
    printf("ok %llu instances in %llu launches\n", done, launches);
    return 0;
}

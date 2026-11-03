/*
 * litmus_runner: run one generated litmus kernel many times on the GPU and count its outcomes.
 *
 *     litmus_runner SPEC PTX OUT_JSON [--instances N] [--config plain|stress|shuffle|spread] [--seed S]
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
 *   mixed         roles share CTAs as the test says (`group k g`: role k is in the g-th CTA of the test), all in one
 *                 cluster: CTA group g is CTA rank g of a cluster, its roles in different warps of that CTA
 *
 * Configurations:
 *   plain    no stress, fixed placement and location layout
 *   stress   threads with no role read and write a 64 MiB scratch buffer while the test runs
 *   shuffle  stress, plus a fresh random placement, location layout and per-thread start delay every launch
 *            (0 to 255 ns, nanosleep)
 *            (for tests with a cluster barrier or a CTA barrier, whole warps are shuffled, never single lanes:
 *            see make_assign)
 *   spread   shuffle with start delays up to 16383 ns instead of 255, so that a reader often runs after
 *            a writer that has more work to do (used for tests whose interesting state is rare otherwise)
 *
 * `init g v [w]` in SPEC: global location g (word w of its line, default 0) starts at v (the host writes it before each
 * launch).
 * `uniform w0 w1 ...` in SPEC: every role is whole warps (role k: wk warps, 1 or 4), all lanes on one instance (the
 * kernel runs warp-wide instructions on all lanes, the others on one lane); a 4-warp role (a warpgroup, for wgmma)
 * starts at warp 0 of its CTA. Warps are not shuffled (delays and the location layout still are).
 * `grid k g` in SPEC: role k runs in launch g (grid g); each launch after the first is a programmatic dependent
 * launch of the one before (griddepcontrol), on one stream.
 * `alias 1` in SPEC: the global memory is mapped twice (driver virtual memory API); the kernel gets the distance
 * between the two mappings as a tenth argument, so that a location and its alias are one memory location.
 * `tmap t b` in SPEC: global location t holds a tensor map (1-dimensional, 4 32-bit elements) whose global address
 * is global location b; the host encodes it before each launch.
 * `dsmem 1` in SPEC: the test reaches shared memory of other CTAs of its cluster; the kernel computes the address of
 * a location in the CTA of test group g as CTA rank g, so ranks are not shuffled (warps, lanes, layout and delays
 * still are), and all roles of an instance use the same slot (bits 3-10), the instance's index in its cluster.
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

enum placement { SAME_CTA, SAME_CLUSTER, DIFF_CLUSTER, MIXED };
static const char *CLASSES[] = {"same-sm", "same-cluster", "diff-cluster"};

struct spec {
    int roles, nregs, ngloc, cluster_barrier, warp_barrier, dsmem, ninit, uniform, ngrids, alias, ntmap;
    int width[CTAS_PER_CLUSTER], grid[CTAS_PER_CLUSTER], tmap_loc[MAXV], tmap_buf[MAXV];
    int group[CTAS_PER_CLUSTER];
    int init_loc[MAXV], init_word[MAXV];
    unsigned init_val[MAXV];
    enum placement place;
};

static int read_spec(const char *path, struct spec *s) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[512], key[64], val[256];
    int a, b, groups = 0;
    memset(s, 0, sizeof *s);
    s->place = -1;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || sscanf(line, "%63s %255s", key, val) != 2) continue;
        if (sscanf(line, "group %d %d", &a, &b) == 2) {
            if (a < 0 || a >= CTAS_PER_CLUSTER || b < 0 || b >= CTAS_PER_CLUSTER) return fclose(f), -1;
            s->group[a] = b, groups++;
            continue;
        }
        if (!strcmp(key, "uniform")) {
            int w[CTAS_PER_CLUSTER] = {0}, n = sscanf(line, "uniform %d %d %d %d", &w[0], &w[1], &w[2], &w[3]);
            for (int k = 0; k < n; k++) {
                if (w[k] != 1 && w[k] != 4) return fclose(f), -1;
                s->width[k] = w[k];
            }
            s->uniform = n;
            continue;
        }
        if (sscanf(line, "grid %d %d", &a, &b) == 2) {
            if (a < 0 || a >= CTAS_PER_CLUSTER || b < 0 || b >= CTAS_PER_CLUSTER) return fclose(f), -1;
            s->grid[a] = b;
            if (b + 1 > s->ngrids) s->ngrids = b + 1;
            continue;
        }
        if (sscanf(line, "tmap %d %d", &a, &b) == 2) {
            if (s->ntmap >= MAXV) return fclose(f), -1;
            s->tmap_loc[s->ntmap] = a, s->tmap_buf[s->ntmap++] = b;
            continue;
        }
        int c = 0;
        if (sscanf(line, "init %d %d %d", &a, &b, &c) >= 2) {
            if (s->ninit >= MAXV || c < 0 || c >= LINE_WORDS) return fclose(f), -1;
            s->init_loc[s->ninit] = a, s->init_word[s->ninit] = c, s->init_val[s->ninit++] = (unsigned)b;
            continue;
        }
        if (!strcmp(key, "roles")) s->roles = atoi(val);
        else if (!strcmp(key, "nregs")) s->nregs = atoi(val);
        else if (!strcmp(key, "ngloc")) s->ngloc = atoi(val);
        else if (!strcmp(key, "cluster_barrier")) s->cluster_barrier = atoi(val);
        else if (!strcmp(key, "warp_barrier")) s->warp_barrier = atoi(val);
        else if (!strcmp(key, "dsmem")) s->dsmem = atoi(val);
        else if (!strcmp(key, "alias")) s->alias = atoi(val);
        else if (!strcmp(key, "placement"))
            s->place = !strcmp(val, "same-cta") ? SAME_CTA : !strcmp(val, "same-cluster") ? SAME_CLUSTER
                     : !strcmp(val, "diff-cluster") ? DIFF_CLUSTER : !strcmp(val, "mixed") ? MIXED : -1;
    }
    fclose(f);
    if (s->roles < 1 || s->roles > CTAS_PER_CLUSTER || (int)s->place < 0 || s->nregs + s->ngloc > MAXV) return -1;
    if ((s->place == MIXED) != (groups == s->roles)) return -1;
    for (int i = 0; i < s->ninit; i++)
        if (s->init_loc[i] < 0 || s->init_loc[i] >= s->ngloc) return -1;
    for (int i = 0; i < s->ntmap; i++)
        if (s->tmap_loc[i] < 0 || s->tmap_loc[i] >= s->ngloc || s->tmap_buf[i] < 0 || s->tmap_buf[i] >= s->ngloc) return -1;
    if (s->uniform && s->uniform != s->roles) return -1;
    if (!s->ngrids) s->ngrids = 1;
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

#define ROLE_WARPS (ROLE_THREADS / 32)

/* The CTA (as an index into the grid) of role k of the instances of unit u, for uniform roles: a unit is one CTA
 * (same-cta) or one cluster; with diff-cluster role k is in cluster (u + k) mod CLUSTERS, CTA rank k. */
static unsigned uniform_cta(const struct spec *s, unsigned u, int k) {
    if (s->place == SAME_CTA) return u;
    if (s->place == DIFF_CLUSTER) return ((u + k) % CLUSTERS) * CTAS_PER_CLUSTER + k;
    return u * CTAS_PER_CLUSTER + (s->place == MIXED ? s->group[k] : k);
}

/* The CTA group of role k (the roles of one group share a CTA). */
static int uniform_group(const struct spec *s, int k) {
    return s->place == SAME_CTA ? 0 : s->place == MIXED ? s->group[k] : k;
}

/* Uniform roles: role k of an instance takes s->width[k] whole warps of its CTA. In each CTA the roles of a group
 * are laid out from warp 0, warpgroup roles first (a warpgroup must start at a warp that is a multiple of 4); the
 * layout repeats for the next instance of the unit (`lslot` = the instance's index in its unit). Returns the number
 * of instances, 0 if they do not fit; `off` gets each role's first warp. */
static unsigned uniform_layout(const struct spec *s, unsigned off[], unsigned span[], unsigned *ni) {
    unsigned wg[CTAS_PER_CLUSTER] = {0};
    for (int g = 0; g < CTAS_PER_CLUSTER; g++) span[g] = 0;
    for (int pass = 0; pass < 2; pass++)
        for (int k = 0; k < s->roles; k++)
            if ((s->width[k] == 4) == (pass == 0)) {
                int g = uniform_group(s, k);
                off[k] = span[g], span[g] += s->width[k], wg[g] += s->width[k] == 4;
            }
    *ni = ROLE_WARPS;
    for (int g = 0; g < CTAS_PER_CLUSTER; g++) {
        if (!span[g]) continue;
        unsigned m = span[g] > ROLE_WARPS || wg[g] > 1 ? 0 : wg[g] ? 1 : ROLE_WARPS / span[g];
        if (m < *ni) *ni = m;
    }
    unsigned units = s->place == SAME_CTA ? NCTAS : CLUSTERS;
    return units * *ni;
}

static unsigned make_assign_uniform(const struct spec *s, unsigned *assign) {
    unsigned off[CTAS_PER_CLUSTER], span[CTAS_PER_CLUSTER], ni, inst = 0;
    for (unsigned i = 0; i < NSLOTS; i++) assign[i] = NONE;
    if (!uniform_layout(s, off, span, &ni) || (s->dsmem && s->place == DIFF_CLUSTER)) return 0;
    unsigned units = s->place == SAME_CTA ? NCTAS : CLUSTERS;
    for (unsigned u = 0; u < units; u++)
        for (unsigned ii = 0; ii < ni; ii++, inst++)
            for (int k = 0; k < s->roles; k++) {
                unsigned cta = uniform_cta(s, u, k), w0 = ii * span[uniform_group(s, k)] + off[k];
                for (unsigned t = 0; t < 32u * s->width[k]; t++)
                    assign[cta * THREADS + w0 * 32 + t] = PACK(inst, (unsigned)k, ii);
            }
    return inst;
}

/* Fill assign for one launch; return the number of instances. */
static unsigned make_assign(const struct spec *s, int random, unsigned *assign) {
    unsigned n = s->roles, inst = 0;
    if (s->uniform) return make_assign_uniform(s, assign);
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
    if (s->dsmem && (s->place == SAME_CTA || s->place == DIFF_CLUSTER)) return 0;
    if (s->place == MIXED) {
        /* group g is CTA rank[g] of each cluster; per CTA, instance group ii uses warps ii*m .. ii*m+m-1 (m: the
         * largest number of roles in one CTA), role k the warp of its index within its group; lane l of every
         * such warp is instance ii*32+l of the group */
        unsigned cnt[CTAS_PER_CLUSTER] = {0}, idx[CTAS_PER_CLUSTER], m = 1, rank[CTAS_PER_CLUSTER];
        unsigned wperm[CTAS_PER_CLUSTER][THREADS / 32], lperm[CTAS_PER_CLUSTER][32];
        for (unsigned k = 0; k < n; k++) idx[k] = cnt[s->group[k]]++;
        for (unsigned g = 0; g < CTAS_PER_CLUSTER; g++) m = cnt[g] > m ? cnt[g] : m;
        unsigned ni = (ROLE_THREADS / 32) / m;
        identity(rank, CTAS_PER_CLUSTER);
        if (random && !s->dsmem) shuffle(rank, CTAS_PER_CLUSTER);
        for (unsigned c = 0; c < CLUSTERS; c++) {
            for (unsigned g = 0; g < CTAS_PER_CLUSTER; g++) {
                identity(wperm[g], THREADS / 32);
                if (random) shuffle(wperm[g], THREADS / 32);
            }
            for (unsigned ii = 0; ii < ni; ii++) {
                for (unsigned k = 0; k < n; k++) {
                    identity(lperm[k], 32);
                    if (random) shuffle(lperm[k], 32);
                }
                for (unsigned l = 0; l < 32; l++, inst++)
                    for (unsigned k = 0; k < n; k++) {
                        unsigned g = s->group[k], cta = c * CTAS_PER_CLUSTER + rank[g];
                        assign[cta * THREADS + wperm[g][ii * m + idx[k]] * 32 + lperm[k][l]] = PACK(inst, k, ii * 32 + l);
                    }
            }
        }
        return inst;
    }
    unsigned rank[CTAS_PER_CLUSTER], step = 1;
    identity(rank, CTAS_PER_CLUSTER);
    if (random && !s->dsmem) shuffle(rank, CTAS_PER_CLUSTER);
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
            if (random && (s->cluster_barrier || s->warp_barrier || s->dsmem)) {
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
                assign[cta * THREADS + sperm[k][t]] = PACK(inst, k, s->dsmem ? t : sperm[k][t] & 255);
            }
    }
    return inst;
}

static int check_assign_uniform(const struct spec *s, const unsigned *assign, unsigned ninst);

/* Check one launch's assignment against the spec: every instance has each role exactly once, the roles are in
 * the CTAs and clusters the placement asks for, and with a barrier every role warp holds one role only.
 * Returns the number of problems (printed). Used by --plan, which needs no GPU. */
static int check_assign(const struct spec *s, const unsigned *assign, unsigned ninst) {
    static unsigned where[NSLOTS][CTAS_PER_CLUSTER];
    int bad = 0;
    if (s->uniform) return check_assign_uniform(s, assign, ninst);
    for (unsigned i = 0; i < ninst; i++)
        for (int k = 0; k < s->roles; k++) where[i][k] = NONE;
    for (unsigned t = 0; t < NSLOTS; t++) {
        unsigned a = assign[t];
        if (a == NONE) continue;
        unsigned role = a & 7, inst = a >> 11;
        if (inst >= ninst || (int)role >= s->roles || where[inst][role] != NONE) {
            if (bad++ < 5) fprintf(stderr, "slot %u: bad or repeated role %u of instance %u\n", t, role, inst);
            continue;
        }
        where[inst][role] = t;
        if (s->warp_barrier || s->cluster_barrier || s->dsmem || s->place == SAME_CTA || s->place == MIXED) {
            unsigned w0 = t / 32 * 32;
            for (unsigned l = 0; l < 32; l++) {
                unsigned b = assign[w0 + l];
                if (b == NONE || (b & 7) != role) {
                    if (bad++ < 5) fprintf(stderr, "slot %u: warp mixes roles or stress threads\n", t);
                    break;
                }
            }
        }
    }
    for (unsigned i = 0; i < ninst; i++)
        for (int k = 0; k < s->roles; k++) {
            if (where[i][k] == NONE) {
                if (bad++ < 5) fprintf(stderr, "instance %u: role %d missing\n", i, k);
                continue;
            }
            unsigned cta = where[i][k] / THREADS, c0 = where[i][0] / THREADS;
            int same_cta = cta == c0, same_cl = cta / CTAS_PER_CLUSTER == c0 / CTAS_PER_CLUSTER;
            int want_cta = s->place == SAME_CTA || (s->place == MIXED && s->group[k] == s->group[0]);
            int want_cl = s->place != DIFF_CLUSTER;
            if (s->dsmem && (((assign[where[i][k]] >> 3) & 255) != ((assign[where[i][0]] >> 3) & 255) ||
                             cta % CTAS_PER_CLUSTER != (unsigned)(s->place == MIXED ? s->group[k] : k))) {
                if (bad++ < 5) fprintf(stderr, "instance %u: role %d not at its CTA rank or slot\n", i, k);
            }
            if (k > 0 && (same_cta != want_cta || (want_cl && !same_cl) || (s->place == DIFF_CLUSTER && same_cl))) {
                if (bad++ < 5) fprintf(stderr, "instance %u: role %d in the wrong CTA or cluster\n", i, k);
            }
        }
    return bad;
}

/* Check a uniform-role assignment: role k of every instance holds exactly 32 * width[k] consecutive slots of one CTA,
 * starting at a warp boundary (a multiple of 4 warps for a warpgroup), and the CTAs follow the placement. */
static int check_assign_uniform(const struct spec *s, const unsigned *assign, unsigned ninst) {
    static unsigned first[NSLOTS][CTAS_PER_CLUSTER], cnt[NSLOTS][CTAS_PER_CLUSTER];
    int bad = 0;
    for (unsigned i = 0; i < ninst; i++)
        for (int k = 0; k < s->roles; k++) first[i][k] = NONE, cnt[i][k] = 0;
    for (unsigned t = 0; t < NSLOTS; t++) {
        unsigned a = assign[t];
        if (a == NONE) continue;
        unsigned role = a & 7, inst = a >> 11;
        if (inst >= ninst || (int)role >= s->roles) {
            if (bad++ < 5) fprintf(stderr, "slot %u: bad role %u of instance %u\n", t, role, inst);
            continue;
        }
        if (first[inst][role] == NONE) first[inst][role] = t;
        if (t != first[inst][role] + cnt[inst][role]++) {
            if (bad++ < 5) fprintf(stderr, "slot %u: role %u of instance %u not in consecutive slots\n", t, role, inst);
        }
    }
    for (unsigned i = 0; i < ninst; i++)
        for (int k = 0; k < s->roles; k++) {
            unsigned w = 32u * s->width[k], f = first[i][k];
            if (f == NONE || cnt[i][k] != w || f % (s->width[k] == 4 ? 128u : 32u)) {
                if (bad++ < 5) fprintf(stderr, "instance %u: role %d has %u slots from %u\n", i, k, cnt[i][k], f);
                continue;
            }
            unsigned cta = f / THREADS, c0 = first[i][0] / THREADS;
            int same_cta = cta == c0, same_cl = cta / CTAS_PER_CLUSTER == c0 / CTAS_PER_CLUSTER;
            int want_cta = s->place == SAME_CTA || (s->place == MIXED && s->group[k] == s->group[0]);
            if (f % THREADS >= ROLE_THREADS || (k > 0 && (same_cta != want_cta ||
                (s->place != DIFF_CLUSTER && !same_cl) || (s->place == DIFF_CLUSTER && same_cl)))) {
                if (bad++ < 5) fprintf(stderr, "instance %u: role %d in the wrong CTA, cluster or warp\n", i, k);
            }
            if (s->dsmem && (cta % CTAS_PER_CLUSTER != (unsigned)(s->place == MIXED ? s->group[k] : k) ||
                             ((assign[f] >> 3) & 255) != ((assign[first[i][0]] >> 3) & 255))) {
                if (bad++ < 5) fprintf(stderr, "instance %u: role %d not at its CTA rank or slot\n", i, k);
            }
        }
    return bad;
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

/* Launch g gets the slots of the roles of grid g; the others are stress threads (or idle). */
static void split_grids(const struct spec *s, const unsigned *assign, unsigned gassign[][NSLOTS]) {
    if (s->ngrids < 2) return;
    for (int g = 0; g < s->ngrids; g++)
        for (unsigned t = 0; t < NSLOTS; t++)
            gassign[g][t] = assign[t] != NONE && s->grid[assign[t] & 7] == g ? assign[t] : NONE;
}

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
    int spread = !strcmp(config, "spread");
    int stress = !strcmp(config, "stress") || !strcmp(config, "shuffle") || spread;
    int random = !strcmp(config, "shuffle") || spread;
    if (!spec_path || (!plan && !out_path) || (strcmp(config, "plain") && !stress)) {
        fprintf(stderr, "usage: litmus_runner SPEC PTX OUT_JSON [--instances N] [--config plain|stress|shuffle|spread]"
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
    if (per_launch == 0) {
        fprintf(stderr, "%s: no instance fits this placement\n", spec_path);
        return 2;
    }
    if (plan) {
        unsigned used = 0;
        for (unsigned i = 0; i < NSLOTS; i++) used += assign[i] != NONE;
        printf("placement %d roles %d instances/launch %u role-threads %u stress-threads %u\n", s.place, s.roles,
               per_launch, used, NSLOTS - used);
        for (unsigned i = 0; i < NSLOTS && i < 2 * THREADS; i += 32)
            printf("slot %u: %08x\n", i, assign[i]);
        int bad = check_assign(&s, assign, per_launch);
        printf("assignment %s\n", bad ? "BAD" : "ok");
        return bad ? 4 : 0;
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
    CUdeviceptr d_mem2 = 0;
    if (s.alias) {
        /* one physical allocation, mapped at two virtual addresses */
        CUmemAllocationProp prop = {0};
        prop.type = CU_MEM_ALLOCATION_TYPE_PINNED;
        prop.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
        prop.location.id = dev;
        size_t gran = 0;
        CHECK(cuMemGetAllocationGranularity(&gran, &prop, CU_MEM_ALLOC_GRANULARITY_MINIMUM));
        size_t sz = (mem_words * 4 + gran - 1) / gran * gran;
        CUmemGenericAllocationHandle h;
        CHECK(cuMemCreate(&h, sz, &prop, 0));
        CHECK(cuMemAddressReserve(&d_mem, sz, 0, 0, 0));
        CHECK(cuMemAddressReserve(&d_mem2, sz, 0, 0, 0));
        CHECK(cuMemMap(d_mem, sz, 0, h, 0));
        CHECK(cuMemMap(d_mem2, sz, 0, h, 0));
        CUmemAccessDesc acc = {0};
        acc.location = prop.location;
        acc.flags = CU_MEM_ACCESS_FLAGS_PROT_READWRITE;
        CHECK(cuMemSetAccess(d_mem, sz, &acc, 1));
        CHECK(cuMemSetAccess(d_mem2, sz, &acc, 1));
    } else {
        CHECK(cuMemAlloc(&d_mem, mem_words * 4));
    }
    unsigned long long adelta = (unsigned long long)(d_mem2 - d_mem);
    CHECK(cuMemAlloc(&d_res, (size_t)per_launch * nrg * 4));
    CHECK(cuMemAlloc(&d_place, (size_t)per_launch * s.roles * 4));
    CHECK(cuMemAlloc(&d_assign, sizeof assign));
    /* one assign array per grid: launch g runs only the roles of grid g */
    static unsigned gassign[CTAS_PER_CLUSTER][NSLOTS];
    CUdeviceptr d_gassign[CTAS_PER_CLUSTER] = {0};
    for (int g = 1; g < s.ngrids; g++) CHECK(cuMemAlloc(&d_gassign[g], sizeof assign));
    d_gassign[0] = d_assign;
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
    split_grids(&s, assign, gassign);
    for (int g = 0; g < s.ngrids; g++) CHECK(cuMemcpyHtoD(d_gassign[g], s.ngrids > 1 ? gassign[g] : assign, sizeof assign));
    CHECK(cuMemcpyHtoD(d_locoff, locoff, (size_t)nlines * 4));

    unsigned scratch_mask = SCRATCH_WORDS - 1, stress_iters = stress ? 512 : 0;
    unsigned delay_mask = spread ? 16383 : random ? 255 : 0;
    /* a tenth argument (the alias distance) is ignored by kernels that take nine */
    void *args[CTAS_PER_CLUSTER][10];
    for (int g = 0; g < s.ngrids; g++) {
        void *a[] = {&d_mem, &d_res, &d_place, &d_gassign[g], &d_locoff, &d_scratch, &scratch_mask, &stress_iters,
                     &delay_mask, &adelta};
        memcpy(args[g], a, sizeof a);
    }
    CUstream stream;
    CHECK(cuStreamCreate(&stream, CU_STREAM_DEFAULT));
    CUlaunchAttribute attr[2] = {{.id = CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION},
                                 {.id = CU_LAUNCH_ATTRIBUTE_PROGRAMMATIC_STREAM_SERIALIZATION}};
    attr[0].value.clusterDim.x = CTAS_PER_CLUSTER, attr[0].value.clusterDim.y = 1, attr[0].value.clusterDim.z = 1;
    attr[1].value.programmaticStreamSerializationAllowed = 1;
    CUlaunchConfig cfg = {.gridDimX = NCTAS, .gridDimY = 1, .gridDimZ = 1, .blockDimX = THREADS, .blockDimY = 1,
                          .blockDimZ = 1, .sharedMemBytes = 0, .hStream = stream, .attrs = attr, .numAttrs = 1};
    unsigned long long done = 0, launches = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    launch_phase = 1;
    while (done < want) {
        if (random && launches > 0) {
            make_assign(&s, 1, assign);
            shuffle(lines, nlines);
            for (unsigned i = 0; i < nlines; i++) locoff[i] = lines[i] * LINE_WORDS;
            split_grids(&s, assign, gassign);
            for (int g = 0; g < s.ngrids; g++)
                CHECK(cuMemcpyHtoD(d_gassign[g], s.ngrids > 1 ? gassign[g] : assign, sizeof assign));
            CHECK(cuMemcpyHtoD(d_locoff, locoff, (size_t)nlines * 4));
        }
        if (s.ninit || s.ntmap) {
            /* initial values: the host writes them before the launch, so every thread sees them */
            memset(mem, 0, mem_words * 4);
            for (unsigned i = 0; i < per_launch; i++)
                for (int j = 0; j < s.ninit; j++)
                    mem[locoff[(size_t)i * ngl + s.init_loc[j]] + s.init_word[j]] = s.init_val[j];
            /* tensor maps: one 1-dimensional map of four 32-bit elements per instance, over its buffer's line */
            for (unsigned i = 0; i < per_launch; i++)
                for (int j = 0; j < s.ntmap; j++) {
                    CUtensorMap m;
                    cuuint64_t dim[1] = {4}, stride[1] = {16};
                    cuuint32_t box[1] = {4}, es[1] = {1};
                    void *base = (void *)(uintptr_t)(d_mem + (CUdeviceptr)locoff[(size_t)i * ngl + s.tmap_buf[j]] * 4);
                    CHECK(cuTensorMapEncodeTiled(&m, CU_TENSOR_MAP_DATA_TYPE_UINT32, 1, base, dim, stride, box, es,
                                                 CU_TENSOR_MAP_INTERLEAVE_NONE, CU_TENSOR_MAP_SWIZZLE_NONE,
                                                 CU_TENSOR_MAP_L2_PROMOTION_NONE, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));
                    memcpy(&mem[locoff[(size_t)i * ngl + s.tmap_loc[j]]], &m, sizeof m);
                }
            CHECK(cuMemcpyHtoD(d_mem, mem, mem_words * 4));
        } else {
            CHECK(cuMemsetD32(d_mem, 0, mem_words));
        }
        CHECK(cuMemsetD32(d_res, 0, (size_t)per_launch * nrg));
        for (int g = 0; g < s.ngrids; g++) {
            cfg.numAttrs = g ? 2 : 1;  /* launches after the first may start early (griddepcontrol.launch_dependents) */
            CHECK(cuLaunchKernelEx(&cfg, fn, args[g], NULL));
        }
        CHECK(cuStreamSynchronize(stream));
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

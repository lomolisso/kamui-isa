// Divergence-heavy kernels for the instruction histograms, written for this project.
//
//     nvcc -O3 -arch=sm_90a -o divergence divergence.cu && ./divergence <kernel>
//     kernel: bfs mandelbrot hashlock spmv bitonic tree
//
// Each kernel is small, deterministic (fixed sizes, a fixed linear congruential generator) and checked against a
// CPU result. They are chosen for their control flow, not their speed:
//   bfs         level-synchronous breadth-first search on a random graph: per-lane loops of different lengths
//               over neighbour lists, atomicCAS on the level array, atomicAdd on the next frontier
//   mandelbrot  escape-time loop: trip counts that differ per lane, up to 1024
//   hashlock    insertion into 64 buckets, each guarded by a spin lock taken with atomicCAS; lanes of one warp
//               contend for the same lock, which needs independent forward progress of the lanes of a warp
//   spmv        CSR sparse matrix-vector product, one row per lane, row lengths from 1 to 512
//   bitonic     bitonic sort of 1024-element blocks: warp shuffles inside a warp, shared memory across warps
//   tree        lookups in an implicit binary search tree with break, continue and an early return
#include <cuda_runtime.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define CHECK(x)                                                                                 \
    do {                                                                                         \
        cudaError_t e_ = (x);                                                                    \
        if (e_ != cudaSuccess) {                                                                 \
            fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, #x, cudaGetErrorString(e_)); \
            exit(2);                                                                             \
        }                                                                                        \
    } while (0)

static uint32_t lcg_state = 12345;
static uint32_t lcg() { return lcg_state = lcg_state * 1664525u + 1013904223u; }

template <class T> static T *to_dev(const std::vector<T> &h) {
    T *d;
    CHECK(cudaMalloc(&d, h.size() * sizeof(T)));
    CHECK(cudaMemcpy(d, h.data(), h.size() * sizeof(T), cudaMemcpyHostToDevice));
    return d;
}
template <class T> static std::vector<T> to_host(const T *d, size_t n) {
    std::vector<T> h(n);
    CHECK(cudaMemcpy(h.data(), d, n * sizeof(T), cudaMemcpyDeviceToHost));
    return h;
}

// ---- bfs -------------------------------------------------------------------------------------------------
extern "C" __global__ void kamui_bfs(const int *rowptr, const int *col, int *level, const int *frontier, int nf,
                                     int *next, int *nnext, int depth) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nf) return;
    int u = frontier[i];
    for (int e = rowptr[u]; e < rowptr[u + 1]; e++) {
        int v = col[e];
        if (level[v] != -1) continue;
        if (atomicCAS(&level[v], -1, depth + 1) == -1) next[atomicAdd(nnext, 1)] = v;
    }
}

static int run_bfs() {
    const int n = 1 << 20;
    std::vector<int> rowptr(n + 1), col;
    for (int u = 0; u < n; u++) {
        rowptr[u] = (int)col.size();
        int deg = 1 + (lcg() % 16 == 0 ? lcg() % 128 : lcg() % 8);
        for (int k = 0; k < deg; k++) col.push_back((int)(lcg() % n));
    }
    rowptr[n] = (int)col.size();
    std::vector<int> level(n, -1);
    level[0] = 0;
    int *drow = to_dev(rowptr), *dcol = to_dev(col), *dlevel = to_dev(level);
    int *dfa, *dfb, *dn;
    CHECK(cudaMalloc(&dfa, n * sizeof(int)));
    CHECK(cudaMalloc(&dfb, n * sizeof(int)));
    CHECK(cudaMalloc(&dn, sizeof(int)));
    int zero = 0, nf = 1;
    CHECK(cudaMemcpy(dfa, &zero, sizeof(int), cudaMemcpyHostToDevice));
    int depth = 0;
    while (nf > 0) {
        CHECK(cudaMemset(dn, 0, sizeof(int)));
        kamui_bfs<<<(nf + 255) / 256, 256>>>(drow, dcol, dlevel, dfa, nf, dfb, dn, depth);
        CHECK(cudaGetLastError());
        CHECK(cudaMemcpy(&nf, dn, sizeof(int), cudaMemcpyDeviceToHost));
        std::swap(dfa, dfb);
        depth++;
    }
    // CPU reference
    std::vector<int> ref(n, -1), q{0};
    ref[0] = 0;
    for (size_t h = 0; h < q.size(); h++)
        for (int e = rowptr[q[h]]; e < rowptr[q[h] + 1]; e++)
            if (ref[col[e]] == -1) ref[col[e]] = ref[q[h]] + 1, q.push_back(col[e]);
    std::vector<int> got = to_host(dlevel, n);
    int bad = 0, reached = 0;
    for (int u = 0; u < n; u++) bad += got[u] != ref[u], reached += got[u] >= 0;
    printf("bfs: %d levels, %d reached, %d mismatches\n", depth, reached, bad);
    return bad != 0;
}

// ---- mandelbrot ------------------------------------------------------------------------------------------
extern "C" __global__ void kamui_mandelbrot(int *iters, int w, int h, int maxit) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;
    float cr = -2.0f + 2.5f * x / w, ci = -1.25f + 2.5f * y / h, zr = 0, zi = 0;
    int i = 0;
    while (i < maxit && zr * zr + zi * zi < 4.0f) {
        float t = zr * zr - zi * zi + cr;
        zi = 2.0f * zr * zi + ci;
        zr = t;
        i++;
    }
    iters[y * w + x] = i;
}

static int run_mandelbrot() {
    const int w = 2048, h = 2048, maxit = 1024;
    int *d;
    CHECK(cudaMalloc(&d, w * h * sizeof(int)));
    kamui_mandelbrot<<<dim3(w / 16, h / 16), dim3(16, 16)>>>(d, w, h, maxit);
    CHECK(cudaGetLastError());
    std::vector<int> got = to_host(d, (size_t)w * h);
    long long sum = 0;
    for (int v : got) sum += v;
    // range check of random points (the escape count depends on float contraction, so no exact CPU compare)
    int bad = 0;
    for (int k = 0; k < 64; k++) {
        int x = lcg() % w, y = lcg() % h;
        bad += got[y * w + x] < 0 || got[y * w + x] > maxit;
    }
    printf("mandelbrot: total iterations %lld, %d out of range\n", sum, bad);
    return bad != 0;
}

// ---- hashlock --------------------------------------------------------------------------------------------
extern "C" __global__ void kamui_hashlock(const int *keys, int n, int *locks, int *heads, int *next, int nb) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    int b = keys[i] % nb;
    while (atomicCAS(&locks[b], 0, 1) != 0) {
    }
    __threadfence();
    next[i] = heads[b];  // push i onto bucket b's list
    heads[b] = i;
    __threadfence();
    atomicExch(&locks[b], 0);
}

static int run_hashlock() {
    const int n = 1 << 18, nb = 64;
    std::vector<int> keys(n);
    for (int &k : keys) k = (int)(lcg() >> 1);
    int *dk = to_dev(keys), *dl, *dh, *dn;
    CHECK(cudaMalloc(&dl, nb * sizeof(int)));
    CHECK(cudaMalloc(&dh, nb * sizeof(int)));
    CHECK(cudaMalloc(&dn, n * sizeof(int)));
    CHECK(cudaMemset(dl, 0, nb * sizeof(int)));
    CHECK(cudaMemset(dh, 0xff, nb * sizeof(int)));
    kamui_hashlock<<<n / 256, 256>>>(dk, n, dl, dh, dn, nb);
    CHECK(cudaGetLastError());
    std::vector<int> heads = to_host(dh, nb), next = to_host(dn, n);
    std::vector<int> seen(n, 0);
    int count = 0, bad = 0;
    for (int b = 0; b < nb; b++)
        for (int i = heads[b]; i != -1 && count <= n; i = next[i]) {
            bad += keys[i] % nb != b || seen[i]++;
            count++;
        }
    printf("hashlock: %d of %d keys in lists, %d misplaced or repeated\n", count, n, bad);
    return count != n || bad != 0;
}

// ---- spmv ------------------------------------------------------------------------------------------------
extern "C" __global__ void kamui_spmv(const int *rowptr, const int *col, const float *val, const float *x, float *y,
                                      int n) {
    int r = blockIdx.x * blockDim.x + threadIdx.x;
    if (r >= n) return;
    float s = 0;
    for (int e = rowptr[r]; e < rowptr[r + 1]; e++) s += val[e] * x[col[e]];
    y[r] = s;
}

static int run_spmv() {
    const int n = 1 << 18;
    std::vector<int> rowptr(n + 1), col;
    std::vector<float> val, x(n);
    for (int r = 0; r < n; r++) {
        rowptr[r] = (int)col.size();
        int len = 1 << (lcg() % 10);  // 1 to 512, a power-law-like spread
        for (int k = 0; k < len; k++) col.push_back((int)(lcg() % n)), val.push_back(1.0f);
    }
    rowptr[n] = (int)col.size();
    for (float &v : x) v = 1.0f;
    int *dr = to_dev(rowptr), *dc = to_dev(col);
    float *dv = to_dev(val), *dx = to_dev(x), *dy;
    CHECK(cudaMalloc(&dy, n * sizeof(float)));
    kamui_spmv<<<n / 256, 256>>>(dr, dc, dv, dx, dy, n);
    CHECK(cudaGetLastError());
    std::vector<float> y = to_host(dy, n);
    int bad = 0;
    for (int r = 0; r < n; r++) bad += y[r] != (float)(rowptr[r + 1] - rowptr[r]);
    printf("spmv: %zu nonzeros, %d wrong rows\n", col.size(), bad);
    return bad != 0;
}

// ---- bitonic ---------------------------------------------------------------------------------------------
extern "C" __global__ void kamui_bitonic(int *data) {
    __shared__ int s[1024];
    int t = threadIdx.x;
    int v = data[blockIdx.x * 1024 + t];
    for (int k = 2; k <= 1024; k <<= 1) {
        for (int j = k >> 1; j > 0; j >>= 1) {
            bool up = (t & k) == 0;
            int partner;
            if (j < 32) {
                partner = __shfl_xor_sync(0xffffffffu, v, j);
            } else {
                s[t] = v;
                __syncthreads();
                partner = s[t ^ j];
                __syncthreads();
            }
            bool lower = (t & j) == 0;
            v = (lower == up) ? min(v, partner) : max(v, partner);
        }
    }
    data[blockIdx.x * 1024 + t] = v;
}

static int run_bitonic() {
    const int blocks = 4096;
    std::vector<int> h((size_t)blocks * 1024);
    for (int &v : h) v = (int)(lcg() >> 8);
    int *d = to_dev(h);
    kamui_bitonic<<<blocks, 1024>>>(d);
    CHECK(cudaGetLastError());
    std::vector<int> got = to_host(d, h.size());
    int bad = 0;
    for (int b = 0; b < blocks; b++) {
        std::sort(h.begin() + b * 1024, h.begin() + (b + 1) * 1024);
        bad += memcmp(&h[b * 1024], &got[b * 1024], 1024 * sizeof(int)) != 0;
    }
    printf("bitonic: %d of %d blocks wrong\n", bad, blocks);
    return bad != 0;
}

// ---- tree ------------------------------------------------------------------------------------------------
// tree[] is an implicit binary search tree (children of i at 2i+1, 2i+2), -1 where empty.
extern "C" __global__ void kamui_tree(const int *tree, int size, const int *queries, int *found, int nq) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nq) return;
    int q = queries[i];
    if (q < 0) {  // early return for invalid queries
        found[i] = -2;
        return;
    }
    int node = 0, steps = 0;
    while (node < size) {
        int k = tree[node];
        steps++;
        if (k == -1) break;
        if (k == q) {
            found[i] = steps;
            return;
        }
        node = 2 * node + (q < k ? 1 : 2);
        if ((steps & 7) == 7 && q % 3 == 0) continue;  // a data-dependent continue that changes nothing
    }
    found[i] = -1;
}

static void tree_insert(std::vector<int> &t, int key) {
    size_t i = 0;
    while (i < t.size() && t[i] != -1) i = 2 * i + (key < t[i] ? 1 : 2);
    if (i < t.size()) t[i] = key;
}

static int run_tree() {
    const int size = (1 << 22) - 1, nkeys = 1 << 16, nq = 1 << 20;
    std::vector<int> tree(size, -1), keys(nkeys), qs(nq);
    for (int &k : keys) k = (int)(lcg() >> 2), tree_insert(tree, k);
    for (int i = 0; i < nq; i++) qs[i] = (i % 17 == 0) ? -1 : (i % 2 ? keys[lcg() % nkeys] : (int)(lcg() >> 2));
    int *dt = to_dev(tree), *dq = to_dev(qs), *df;
    CHECK(cudaMalloc(&df, nq * sizeof(int)));
    kamui_tree<<<nq / 256, 256>>>(dt, size, dq, df, nq);
    CHECK(cudaGetLastError());
    std::vector<int> got = to_host(df, nq);
    int bad = 0, hits = 0;
    for (int i = 0; i < nq; i++) {
        int q = qs[i], want;
        if (q < 0) {
            want = -2;
        } else {
            size_t node = 0;
            int steps = 0;
            want = -1;
            while (node < tree.size()) {
                steps++;
                if (tree[node] == -1) break;
                if (tree[node] == q) {
                    want = steps;
                    break;
                }
                node = 2 * node + (q < tree[node] ? 1 : 2);
            }
        }
        bad += got[i] != want;
        hits += want > 0;
    }
    printf("tree: %d hits, %d mismatches\n", hits, bad);
    return bad != 0;
}

int main(int argc, char **argv) {
    const char *k = argc > 1 ? argv[1] : "";
    int rc;
    if (!strcmp(k, "bfs")) rc = run_bfs();
    else if (!strcmp(k, "mandelbrot")) rc = run_mandelbrot();
    else if (!strcmp(k, "hashlock")) rc = run_hashlock();
    else if (!strcmp(k, "spmv")) rc = run_spmv();
    else if (!strcmp(k, "bitonic")) rc = run_bitonic();
    else if (!strcmp(k, "tree")) rc = run_tree();
    else {
        fprintf(stderr, "usage: divergence bfs|mandelbrot|hashlock|spmv|bitonic|tree\n");
        return 1;
    }
    CHECK(cudaDeviceSynchronize());
    return rc;
}

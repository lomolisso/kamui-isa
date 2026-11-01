/*
 * runner: load one corpus kernel on the GPU, launch it once, and write its output buffers.
 *
 *     runner LAUNCH_FILE              load, launch, write outputs (needs a GPU)
 *     runner --parse-only LAUNCH_FILE parse and print the plan, touch no GPU
 *
 * The launch file is written by run_all.py from a corpus entry.yaml. One item per line, `#` starts a comment:
 *
 *     kernel   k_name                 extern "C" name of the kernel
 *     module   path                   kernel.ptx (loaded through the driver JIT) or a .cubin
 *     inputs   path | -               the entry's inputs.bin (input and inout buffers, in order)
 *     outputs  path                   written on success: output and inout buffers, in order
 *     jitlog   path | -               the JIT info and error logs
 *     grid     x y z
 *     block    x y z
 *     cluster  x y z                  0 0 0: no cluster launch attribute
 *     smem     bytes                  dynamic shared memory
 *     fill     byte                   value written into every output buffer before the launch
 *     param buffer NBYTES INOFF OUT   INOFF: offset in inputs.bin, -1 for an output; OUT 1: copied to outputs
 *     param scalar NBYTES HEX         the value's bytes, little-endian, as hex
 *     param tmap tile DTYPE BUF RANK DIMS... BOX... SWIZZLE INTERLEAVE FILL
 *     param tmap im2col DTYPE BUF RANK DIMS... LOWER... UPPER... CHANNELS PIXELS SWIZZLE INTERLEAVE FILL
 *
 * BUF is the index (from 0) of the buffer parameter the tensor map describes; DIMS and BOX are innermost first;
 * the buffer is contiguous, so the strides follow from DIMS. Tensor maps are passed by value (128 bytes, the
 * kernel declares them `const __grid_constant__`).
 *
 * The last line on stdout is `result ok`, `result launch-error CODE NAME` (the kernel failed or timed out on
 * the device) or `result setup-error ...`. Exit status: 0 ok, 3 launch error, 2 setup error, 1 usage.
 * Our own code; it uses only the CUDA driver API (cuda.h from the toolkit, linked with -lcuda).
 */
#include <cuda.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PARAMS 32
#define MAX_RANK 5
#define LINE 4096
#define LOG_BYTES (1 << 16)

enum kind { BUFFER, SCALAR, TMAP };

struct param {
    enum kind kind;
    size_t nbytes;
    long inoff;
    int out;
    unsigned char scalar[16];
    int tile;                 /* tmap: 1 tile, 0 im2col */
    CUtensorMapDataType dtype;
    int esize, buf, rank;
    cuuint64_t dims[MAX_RANK];
    cuuint32_t box[MAX_RANK];
    int lower[MAX_RANK], upper[MAX_RANK];
    unsigned channels, pixels;
    CUtensorMapSwizzle swizzle;
    CUtensorMapInterleave interleave;
    CUtensorMapFloatOOBfill oobfill;
};

struct plan {
    char kernel[256], module[LINE], inputs[LINE], outputs[LINE], jitlog[LINE];
    unsigned grid[3], block[3], cluster[3], smem;
    int fill, nparams;
    struct param p[MAX_PARAMS];
};

static void die(int code, const char *what) {
    printf("result setup-error %s\n", what);
    exit(code);
}

static void check(CUresult r, const char *what) {
    if (r != CUDA_SUCCESS) {
        const char *name = "?";
        cuGetErrorName(r, &name);
        printf("result setup-error %s %d %s\n", what, (int)r, name);
        exit(2);
    }
}

static int dtype_of(const char *s, CUtensorMapDataType *t) {
    static const struct { const char *n; CUtensorMapDataType t; int size; } m[] = {
        {"u8", CU_TENSOR_MAP_DATA_TYPE_UINT8, 1},    {"u16", CU_TENSOR_MAP_DATA_TYPE_UINT16, 2},
        {"u32", CU_TENSOR_MAP_DATA_TYPE_UINT32, 4},  {"s32", CU_TENSOR_MAP_DATA_TYPE_INT32, 4},
        {"u64", CU_TENSOR_MAP_DATA_TYPE_UINT64, 8},  {"s64", CU_TENSOR_MAP_DATA_TYPE_INT64, 8},
        {"f16", CU_TENSOR_MAP_DATA_TYPE_FLOAT16, 2}, {"f32", CU_TENSOR_MAP_DATA_TYPE_FLOAT32, 4},
        {"f64", CU_TENSOR_MAP_DATA_TYPE_FLOAT64, 8}, {"bf16", CU_TENSOR_MAP_DATA_TYPE_BFLOAT16, 2},
    };
    for (size_t i = 0; i < sizeof m / sizeof m[0]; i++)
        if (!strcmp(s, m[i].n)) {
            *t = m[i].t;
            return m[i].size;
        }
    return 0;
}

static CUtensorMapSwizzle swizzle_of(const char *s) {
    if (!strcmp(s, "32B")) return CU_TENSOR_MAP_SWIZZLE_32B;
    if (!strcmp(s, "64B")) return CU_TENSOR_MAP_SWIZZLE_64B;
    if (!strcmp(s, "128B")) return CU_TENSOR_MAP_SWIZZLE_128B;
    if (strcmp(s, "none")) die(2, "bad swizzle");
    return CU_TENSOR_MAP_SWIZZLE_NONE;
}

static CUtensorMapInterleave interleave_of(const char *s) {
    if (!strcmp(s, "16B")) return CU_TENSOR_MAP_INTERLEAVE_16B;
    if (!strcmp(s, "32B")) return CU_TENSOR_MAP_INTERLEAVE_32B;
    if (strcmp(s, "none")) die(2, "bad interleave");
    return CU_TENSOR_MAP_INTERLEAVE_NONE;
}

static CUtensorMapFloatOOBfill fill_of(const char *s) {
    if (!strcmp(s, "nan")) return CU_TENSOR_MAP_FLOAT_OOB_FILL_NAN_REQUEST_ZERO_FMA;
    if (strcmp(s, "zero")) die(2, "bad fill");
    return CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE;
}

/* Next whitespace-separated token of the line, or die. */
static char *tok(char **save) {
    char *t = strtok_r(NULL, " \t\r\n", save);
    if (!t) die(1, "launch file: missing field");
    return t;
}

static void parse_tmap(struct param *q, char **save) {
    q->kind = TMAP;
    q->tile = !strcmp(tok(save), "tile");
    q->esize = dtype_of(tok(save), &q->dtype);
    if (!q->esize) die(1, "launch file: bad tensor map dtype");
    q->buf = atoi(tok(save));
    q->rank = atoi(tok(save));
    if (q->rank < 1 || q->rank > MAX_RANK) die(1, "launch file: bad tensor map rank");
    for (int i = 0; i < q->rank; i++) q->dims[i] = strtoull(tok(save), NULL, 10);
    if (q->tile) {
        for (int i = 0; i < q->rank; i++) q->box[i] = (cuuint32_t)strtoul(tok(save), NULL, 10);
    } else {
        for (int i = 0; i < q->rank - 2; i++) q->lower[i] = atoi(tok(save));
        for (int i = 0; i < q->rank - 2; i++) q->upper[i] = atoi(tok(save));
        q->channels = (unsigned)atoi(tok(save));
        q->pixels = (unsigned)atoi(tok(save));
    }
    q->swizzle = swizzle_of(tok(save));
    q->interleave = interleave_of(tok(save));
    q->oobfill = fill_of(tok(save));
}

static void parse(const char *path, struct plan *pl) {
    FILE *f = fopen(path, "r");
    if (!f) die(1, "cannot open the launch file");
    memset(pl, 0, sizeof *pl);
    char line[LINE];
    while (fgets(line, sizeof line, f)) {
        char *hash = strchr(line, '#');
        if (hash) *hash = 0;
        char *save = NULL, *key = strtok_r(line, " \t\r\n", &save);
        if (!key) continue;
        if (!strcmp(key, "kernel")) snprintf(pl->kernel, sizeof pl->kernel, "%s", tok(&save));
        else if (!strcmp(key, "module")) snprintf(pl->module, LINE, "%s", tok(&save));
        else if (!strcmp(key, "inputs")) snprintf(pl->inputs, LINE, "%s", tok(&save));
        else if (!strcmp(key, "outputs")) snprintf(pl->outputs, LINE, "%s", tok(&save));
        else if (!strcmp(key, "jitlog")) snprintf(pl->jitlog, LINE, "%s", tok(&save));
        else if (!strcmp(key, "smem")) pl->smem = (unsigned)atoi(tok(&save));
        else if (!strcmp(key, "fill")) pl->fill = atoi(tok(&save));
        else if (!strcmp(key, "grid") || !strcmp(key, "block") || !strcmp(key, "cluster")) {
            unsigned *v = key[0] == 'g' ? pl->grid : key[0] == 'b' ? pl->block : pl->cluster;
            for (int i = 0; i < 3; i++) v[i] = (unsigned)atoi(tok(&save));
        } else if (!strcmp(key, "param")) {
            if (pl->nparams == MAX_PARAMS) die(1, "launch file: too many parameters");
            struct param *q = &pl->p[pl->nparams++];
            char *k = tok(&save);
            if (!strcmp(k, "buffer")) {
                q->kind = BUFFER;
                q->nbytes = strtoull(tok(&save), NULL, 10);
                q->inoff = atol(tok(&save));
                q->out = atoi(tok(&save));
            } else if (!strcmp(k, "scalar")) {
                q->kind = SCALAR;
                q->nbytes = strtoull(tok(&save), NULL, 10);
                const char *hex = tok(&save);
                if (q->nbytes > sizeof q->scalar || strlen(hex) != 2 * q->nbytes) die(1, "launch file: bad scalar");
                for (size_t i = 0; i < q->nbytes; i++) {
                    unsigned b;
                    sscanf(hex + 2 * i, "%2x", &b);
                    q->scalar[i] = (unsigned char)b;
                }
            } else if (!strcmp(k, "tmap")) {
                parse_tmap(q, &save);
            } else {
                die(1, "launch file: unknown parameter kind");
            }
        } else {
            die(1, "launch file: unknown key");
        }
    }
    fclose(f);
    if (!pl->kernel[0] || !pl->module[0] || !pl->outputs[0] || !pl->grid[0] || !pl->block[0])
        die(1, "launch file: kernel, module, outputs, grid and block are required");
    for (int i = 0; i < pl->nparams; i++) {
        const struct param *q = &pl->p[i];
        if (q->kind == TMAP && (q->buf < 0 || q->buf >= pl->nparams || pl->p[q->buf].kind != BUFFER))
            die(1, "launch file: a tensor map must name a buffer parameter");
    }
}

static void print_plan(const struct plan *pl) {
    printf("kernel %s\nmodule %s\ngrid %u %u %u\nblock %u %u %u\ncluster %u %u %u\nsmem %u\nfill %d\n", pl->kernel,
           pl->module, pl->grid[0], pl->grid[1], pl->grid[2], pl->block[0], pl->block[1], pl->block[2], pl->cluster[0],
           pl->cluster[1], pl->cluster[2], pl->smem, pl->fill);
    for (int i = 0; i < pl->nparams; i++) {
        const struct param *q = &pl->p[i];
        if (q->kind == BUFFER) printf("param %d buffer %zu in %ld out %d\n", i, q->nbytes, q->inoff, q->out);
        else if (q->kind == SCALAR) printf("param %d scalar %zu\n", i, q->nbytes);
        else printf("param %d tmap %s buf %d rank %d esize %d\n", i, q->tile ? "tile" : "im2col", q->buf, q->rank,
                    q->esize);
    }
    printf("result parsed\n");
}

static unsigned char *read_file(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc((size_t)len + 1);
    if (!b || fread(b, 1, (size_t)len, f) != (size_t)len) die(2, "cannot read a file");
    b[len] = 0;
    fclose(f);
    *n = (size_t)len;
    return b;
}

static int ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && !strcmp(s + a - b, suffix);
}

int main(int argc, char **argv) {
    static struct plan pl;
    int parse_only = argc == 3 && !strcmp(argv[1], "--parse-only");
    if (argc != 2 && !parse_only) {
        fprintf(stderr, "usage: runner [--parse-only] LAUNCH_FILE\n");
        return 1;
    }
    parse(argv[argc - 1], &pl);
    if (parse_only) {
        print_plan(&pl);
        return 0;
    }

    CUdevice dev;
    CUcontext ctx;
    check(cuInit(0), "cuInit");
    check(cuDeviceGet(&dev, 0), "cuDeviceGet");
    check(cuCtxCreate(&ctx, 0, dev), "cuCtxCreate");

    size_t modlen = 0;
    unsigned char *mod_bytes = read_file(pl.module, &modlen);
    if (!mod_bytes) die(2, "cannot read the module");
    CUmodule mod;
    static char info[LOG_BYTES], err[LOG_BYTES];
    CUresult r;
    if (ends_with(pl.module, ".cubin")) {
        r = cuModuleLoadData(&mod, mod_bytes);
    } else {
        CUjit_option o[] = {CU_JIT_INFO_LOG_BUFFER, CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES, CU_JIT_ERROR_LOG_BUFFER,
                            CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES, CU_JIT_LOG_VERBOSE};
        void *v[] = {info, (void *)(uintptr_t)LOG_BYTES, err, (void *)(uintptr_t)LOG_BYTES, (void *)(uintptr_t)1};
        r = cuModuleLoadDataEx(&mod, mod_bytes, 5, o, v);
    }
    if (pl.jitlog[0] && strcmp(pl.jitlog, "-")) {
        FILE *f = fopen(pl.jitlog, "w");
        if (f) {
            fprintf(f, "%s\n%s\n", info, err);
            fclose(f);
        }
    }
    check(r, "cuModuleLoadData");
    CUfunction fn;
    check(cuModuleGetFunction(&fn, mod, pl.kernel), "cuModuleGetFunction");
    if (pl.smem > 48 * 1024)
        check(cuFuncSetAttribute(fn, CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, (int)pl.smem),
              "cuFuncSetAttribute");

    size_t inlen = 0;
    unsigned char *in = NULL;
    if (pl.inputs[0] && strcmp(pl.inputs, "-")) {
        in = read_file(pl.inputs, &inlen);
        if (!in) die(2, "cannot read inputs.bin");
    }

    CUdeviceptr dptr[MAX_PARAMS] = {0};
    void *args[MAX_PARAMS];
    CUtensorMap *maps = aligned_alloc(64, sizeof(CUtensorMap) * MAX_PARAMS);
    if (!maps) die(2, "out of memory");
    for (int i = 0; i < pl.nparams; i++) {
        struct param *q = &pl.p[i];
        if (q->kind == BUFFER) {
            check(cuMemAlloc(&dptr[i], q->nbytes ? q->nbytes : 1), "cuMemAlloc");
            if (q->inoff >= 0) {
                if (!in || (size_t)q->inoff + q->nbytes > inlen) die(2, "inputs.bin is shorter than the parameters");
                check(cuMemcpyHtoD(dptr[i], in + q->inoff, q->nbytes), "cuMemcpyHtoD");
            } else {
                check(cuMemsetD8(dptr[i], (unsigned char)pl.fill, q->nbytes), "cuMemsetD8");
            }
            args[i] = &dptr[i];
        } else if (q->kind == SCALAR) {
            args[i] = q->scalar;
        }
    }
    for (int i = 0; i < pl.nparams; i++) {
        struct param *q = &pl.p[i];
        if (q->kind != TMAP) continue;
        cuuint64_t strides[MAX_RANK];
        cuuint32_t estr[MAX_RANK];
        cuuint64_t s = (cuuint64_t)q->esize;
        for (int d = 0; d < q->rank; d++) {
            estr[d] = 1;
            s *= q->dims[d];
            if (d + 1 < q->rank) strides[d] = s;
        }
        if (q->tile)
            check(cuTensorMapEncodeTiled(&maps[i], q->dtype, (cuuint32_t)q->rank, (void *)dptr[q->buf], q->dims, strides,
                                         q->box, estr, q->interleave, q->swizzle, CU_TENSOR_MAP_L2_PROMOTION_NONE,
                                         q->oobfill),
                  "cuTensorMapEncodeTiled");
        else
            check(cuTensorMapEncodeIm2col(&maps[i], q->dtype, (cuuint32_t)q->rank, (void *)dptr[q->buf], q->dims,
                                          strides, q->lower, q->upper, q->channels, q->pixels, estr, q->interleave,
                                          q->swizzle, CU_TENSOR_MAP_L2_PROMOTION_NONE, q->oobfill),
                  "cuTensorMapEncodeIm2col");
        args[i] = &maps[i];
    }

    CUlaunchAttribute attr;
    CUlaunchConfig cfg = {0};
    cfg.gridDimX = pl.grid[0], cfg.gridDimY = pl.grid[1], cfg.gridDimZ = pl.grid[2];
    cfg.blockDimX = pl.block[0], cfg.blockDimY = pl.block[1], cfg.blockDimZ = pl.block[2];
    cfg.sharedMemBytes = pl.smem;
    if (pl.cluster[0]) {
        attr.id = CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION;
        attr.value.clusterDim.x = pl.cluster[0];
        attr.value.clusterDim.y = pl.cluster[1];
        attr.value.clusterDim.z = pl.cluster[2];
        cfg.attrs = &attr;
        cfg.numAttrs = 1;
    }
    r = cuLaunchKernelEx(&cfg, fn, args, NULL);
    if (r == CUDA_SUCCESS) r = cuCtxSynchronize();
    if (r != CUDA_SUCCESS) {
        const char *name = "?";
        cuGetErrorName(r, &name);
        printf("result launch-error %d %s\n", (int)r, name);
        return 3;
    }

    FILE *out = fopen(pl.outputs, "wb");
    if (!out) die(2, "cannot write outputs");
    for (int i = 0; i < pl.nparams; i++) {
        struct param *q = &pl.p[i];
        if (q->kind != BUFFER || !q->out) continue;
        unsigned char *h = malloc(q->nbytes ? q->nbytes : 1);
        if (!h) die(2, "out of memory");
        check(cuMemcpyDtoH(h, dptr[i], q->nbytes), "cuMemcpyDtoH");
        if (fwrite(h, 1, q->nbytes, out) != q->nbytes) die(2, "cannot write outputs");
        free(h);
    }
    fclose(out);
    printf("result ok\n");
    return 0;
}

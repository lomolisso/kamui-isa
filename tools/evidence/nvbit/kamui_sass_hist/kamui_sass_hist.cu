// kamui_sass_hist: an NVBit tool that counts how often each SASS opcode executes in the kernels of a program.
//
//     LD_PRELOAD=kamui_sass_hist.so KAMUI_OUT=out.csv KAMUI_WORKLOAD=name [KAMUI_KERNELS=regex]
//         [KAMUI_EXCLUDE=regex] [KAMUI_KERNELS_OUT=kernels.csv] ./program
//
// The first launch of each kernel whose name matches KAMUI_KERNELS (default: every kernel) and does not match
// KAMUI_EXCLUDE (default: none) is instrumented:
// before every SASS instruction a small device function adds one warp issue, the number of active lanes, and
// the number of active lanes whose guard predicate is true. Later launches of the same kernel run without
// instrumentation. Instructions guarded by @!PT never execute and are left out.
//
// At exit the tool writes one CSV row per kernel and SASS opcode (opcode with its modifiers, operands dropped):
//     workload,kernel,sass_opcode,static_count,warp_inst_executed,thread_inst_executed,thread_inst_executed_pred_true
// so the output is a histogram, not an instruction trace. With KAMUI_KERNELS_OUT the tool also writes one row per
// counted kernel with its attributes and register use (see write_kernels below); again counts only, no SASS. `kernel` is the kernel's name up to the first `(` or
// `<`, plus `#` and 8 hex digits of a hash of the full mangled name, which tells apart template instances.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <algorithm>
#include <map>
#include <mutex>
#include <regex>
#include <set>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>

#include "nvbit.h"
#include "nvbit_tool.h"

#define MAX_SLOTS (1 << 21)
__managed__ uint64_t counters[3 * MAX_SLOTS];

struct Slot { std::string opcode; uint64_t index; };
struct Totals { uint64_t statics = 0, warp = 0, thread = 0, pred = 0; };

// Per counted kernel: attributes from the driver, the launch configuration of its first launch, and what the
// instruction operands show (highest register numbers used, convergence-barrier and setmaxnreg instructions).
struct KernelInfo {
    std::string name;
    int regs = -1, local_bytes = -1, shared_static = -1, const_bytes = -1, max_threads = -1, ptx_version = -1;
    int req_cluster[3] = {0, 0, 0};
    unsigned grid[3] = {0, 0, 0}, block[3] = {0, 0, 0}, cluster[3] = {0, 0, 0}, dyn_shared = 0;
    int max_r = -1, max_ur = -1, max_p = -1, max_up = -1;
    uint64_t instrs = 0;
    std::map<std::string, uint64_t> marks;  // static count of selected opcode families
    std::set<uint64_t> setmaxnreg;          // immediates of USETMAXREG
};
static std::map<CUfunction, KernelInfo> kinfo;
static std::string kernels_out;
static std::regex exclude_re;
static bool has_exclude = false;

static std::recursive_mutex mtx;
static std::unordered_map<CUfunction, std::vector<Slot>> slots;  // per instrumented function
static std::set<CUfunction> counted;                              // kernels whose first launch was counted
static std::map<std::pair<std::string, std::string>, Totals> hist;  // (kernel, opcode) -> totals
static uint64_t next_slot = 0;
static std::string out_path = "kamui_sass_hist.csv", workload = "unknown";
static std::regex kernel_re(".*");
static CUfunction pending = nullptr;
static bool overflow = false;

static std::string short_name(CUcontext ctx, CUfunction f) {
    std::string mangled = nvbit_get_func_name(ctx, f, true);
    std::string name = nvbit_get_func_name(ctx, f, false);
    size_t cut = name.find_first_of("(<");
    if (cut != std::string::npos) name = name.substr(0, cut);
    uint32_t h = 2166136261u;  // FNV-1a
    for (unsigned char ch : mangled) h = (h ^ ch) * 16777619u;
    char tag[16];
    snprintf(tag, sizeof tag, "#%08x", h);
    for (char &ch : name)
        if (ch == ',' || ch == '"' || ch == '\n') ch = '_';
    return name + tag;
}

void nvbit_at_init() {
    const char *v;
    if ((v = getenv("KAMUI_OUT"))) out_path = v;
    if ((v = getenv("KAMUI_WORKLOAD"))) workload = v;
    if ((v = getenv("KAMUI_KERNELS"))) kernel_re = std::regex(v);
    if ((v = getenv("KAMUI_EXCLUDE")) && *v) {
        exclude_re = std::regex(v);
        has_exclude = true;
    }
    if ((v = getenv("KAMUI_KERNELS_OUT"))) kernels_out = v;
}

// Register numbers that mean "zero" or "true" and are not allocated: RZ, URZ, PT, UPT.
static void note_regs(KernelInfo &k, const InstrType::operand_t *op) {
    int words = op->nbytes > 4 ? op->nbytes / 4 : 1;
    switch (op->type) {
    case InstrType::OperandType::REG:
        if (op->u.reg.num != 255) k.max_r = std::max(k.max_r, op->u.reg.num + words - 1);
        break;
    case InstrType::OperandType::UREG:
        if (op->u.reg.num != 63) k.max_ur = std::max(k.max_ur, op->u.reg.num + words - 1);
        break;
    case InstrType::OperandType::PRED:
        if (op->u.pred.num != 7) k.max_p = std::max(k.max_p, op->u.pred.num);
        break;
    case InstrType::OperandType::UPRED:
        if (op->u.pred.num != 7) k.max_up = std::max(k.max_up, op->u.pred.num);
        break;
    case InstrType::OperandType::MREF: {
        int w = op->u.mref.ra_mod == InstrType::RegModifierType::U64 ? 2 : 1;
        if (op->u.mref.has_ra && op->u.mref.ra_num != 255) k.max_r = std::max(k.max_r, op->u.mref.ra_num + w - 1);
        if (op->u.mref.has_ur && op->u.mref.ur_num != 63) k.max_ur = std::max(k.max_ur, op->u.mref.ur_num + 1);
        if (op->u.mref.has_desc && op->u.mref.desc_ureg_num != 63)
            k.max_ur = std::max(k.max_ur, op->u.mref.desc_ureg_num + 1);
        break;
    }
    case InstrType::OperandType::MEM_DESC:
        if (op->u.mem_desc.ureg_num != 63) k.max_ur = std::max(k.max_ur, op->u.mem_desc.ureg_num + 1);
        break;
    default:
        break;
    }
}

// Opcode families recorded per kernel (static counts), by the opcode's first word.
static const char *MARKS[] = {"BSSY", "BSYNC", "BMOV", "BREAK", "WARPSYNC", "BPT", "YIELD", "USETMAXREG",
                              "REDUX", "VOTEU", "S2UR", "R2UR", "ELECT", "QSPC", "MEMBAR", "CCTL", "ERRBAR",
                              "FENCE", "SYNCS", "HGMMA", "UTMALDG", "UBLKCP", "LDGSTS", "CALL", "RET"};

static void scan(CUcontext ctx, CUfunction f, KernelInfo &k) {
    for (Instr *i : nvbit_get_instrs(ctx, f)) {
        k.instrs++;
        std::string op = i->getOpcode();
        std::string head = op.substr(0, op.find('.'));
        for (const char *m : MARKS)
            if (head == m) k.marks[m]++;
        for (int n = 0; n < i->getNumOperands(); n++) {
            const InstrType::operand_t *o = i->getOperand(n);
            note_regs(k, o);
            if (head == "USETMAXREG" && o->type == InstrType::OperandType::IMM_UINT64)
                k.setmaxnreg.insert(o->u.imm_uint64.value);
        }
    }
}

static void describe(CUcontext ctx, CUfunction f, nvbit_api_cuda_t cbid, void *params) {
    KernelInfo &k = kinfo[f];
    k.name = short_name(ctx, f);
    cuFuncGetAttribute(&k.regs, CU_FUNC_ATTRIBUTE_NUM_REGS, f);
    cuFuncGetAttribute(&k.local_bytes, CU_FUNC_ATTRIBUTE_LOCAL_SIZE_BYTES, f);
    cuFuncGetAttribute(&k.shared_static, CU_FUNC_ATTRIBUTE_SHARED_SIZE_BYTES, f);
    cuFuncGetAttribute(&k.const_bytes, CU_FUNC_ATTRIBUTE_CONST_SIZE_BYTES, f);
    cuFuncGetAttribute(&k.max_threads, CU_FUNC_ATTRIBUTE_MAX_THREADS_PER_BLOCK, f);
    cuFuncGetAttribute(&k.ptx_version, CU_FUNC_ATTRIBUTE_PTX_VERSION, f);
    cuFuncGetAttribute(&k.req_cluster[0], CU_FUNC_ATTRIBUTE_REQUIRED_CLUSTER_WIDTH, f);
    cuFuncGetAttribute(&k.req_cluster[1], CU_FUNC_ATTRIBUTE_REQUIRED_CLUSTER_HEIGHT, f);
    cuFuncGetAttribute(&k.req_cluster[2], CU_FUNC_ATTRIBUTE_REQUIRED_CLUSTER_DEPTH, f);
    if (cbid == API_CUDA_cuLaunchKernel || cbid == API_CUDA_cuLaunchKernel_ptsz) {
        auto *p = (cuLaunchKernel_params *)params;
        unsigned g[3] = {p->gridDimX, p->gridDimY, p->gridDimZ}, b[3] = {p->blockDimX, p->blockDimY, p->blockDimZ};
        for (int d = 0; d < 3; d++) k.grid[d] = g[d], k.block[d] = b[d];
        k.dyn_shared = p->sharedMemBytes;
    } else {
        const CUlaunchConfig *c = ((cuLaunchKernelEx_params *)params)->config;
        unsigned g[3] = {c->gridDimX, c->gridDimY, c->gridDimZ}, b[3] = {c->blockDimX, c->blockDimY, c->blockDimZ};
        for (int d = 0; d < 3; d++) k.grid[d] = g[d], k.block[d] = b[d];
        k.dyn_shared = c->sharedMemBytes;
        for (unsigned a = 0; a < c->numAttrs; a++)
            if (c->attrs[a].id == CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION) {
                k.cluster[0] = c->attrs[a].value.clusterDim.x;
                k.cluster[1] = c->attrs[a].value.clusterDim.y;
                k.cluster[2] = c->attrs[a].value.clusterDim.z;
            }
    }
    std::vector<CUfunction> funcs = nvbit_get_related_functions(ctx, f);
    funcs.push_back(f);
    for (CUfunction fn : funcs) scan(ctx, fn, k);
}

static void instrument(CUcontext ctx, CUfunction f) {
    std::vector<CUfunction> funcs = nvbit_get_related_functions(ctx, f);
    funcs.push_back(f);
    for (CUfunction fn : funcs) {
        if (slots.count(fn)) continue;
        std::vector<Slot> &v = slots[fn];
        for (Instr *i : nvbit_get_instrs(ctx, fn)) {
            std::string sass = i->getSass();
            if (sass.rfind("@!PT", 0) == 0) continue;
            if (next_slot >= MAX_SLOTS) {
                overflow = true;
                continue;
            }
            uint64_t k = next_slot++;
            v.push_back({i->getOpcode(), k});
            nvbit_insert_call(i, "kamui_count", IPOINT_BEFORE);
            nvbit_add_call_arg_guard_pred_val(i);
            nvbit_add_call_arg_const_val64(i, (uint64_t)&counters[3 * k]);
        }
    }
}

static void harvest(CUcontext ctx, CUfunction f) {
    cudaDeviceSynchronize();
    std::string kname = short_name(ctx, f);
    std::vector<CUfunction> funcs = nvbit_get_related_functions(ctx, f);
    funcs.push_back(f);
    for (CUfunction fn : funcs) {
        for (const Slot &s : slots[fn]) {
            Totals &t = hist[{kname, s.opcode}];
            t.statics += 1;
            t.warp += counters[3 * s.index];
            t.thread += counters[3 * s.index + 1];
            t.pred += counters[3 * s.index + 2];
            counters[3 * s.index] = counters[3 * s.index + 1] = counters[3 * s.index + 2] = 0;
        }
    }
}

void nvbit_at_cuda_event(CUcontext ctx, int is_exit, nvbit_api_cuda_t cbid, const char *name, void *params,
                         CUresult *pStatus) {
    (void)name;
    (void)pStatus;
    CUfunction f = nullptr;
    if (cbid == API_CUDA_cuLaunchKernel || cbid == API_CUDA_cuLaunchKernel_ptsz)
        f = ((cuLaunchKernel_params *)params)->f;
    else if (cbid == API_CUDA_cuLaunchKernelEx || cbid == API_CUDA_cuLaunchKernelEx_ptsz)
        f = ((cuLaunchKernelEx_params *)params)->f;
    if (!f) return;
    std::lock_guard<std::recursive_mutex> lock(mtx);
    if (!is_exit) {
        const char *fname = nvbit_get_func_name(ctx, f, false);
        bool want = !counted.count(f) && std::regex_search(fname, kernel_re) &&
                    !(has_exclude && std::regex_search(fname, exclude_re));
        if (want) {
            if (!kernels_out.empty()) describe(ctx, f, cbid, params);
            instrument(ctx, f);
            pending = f;
        }
        nvbit_enable_instrumented(ctx, f, want);
    } else if (pending == f) {
        harvest(ctx, f);
        counted.insert(f);
        pending = nullptr;
    }
}

static void write_kernels() {
    FILE *o = fopen(kernels_out.c_str(), "w");
    if (!o) {
        fprintf(stderr, "kamui_sass_hist: cannot write %s\n", kernels_out.c_str());
        return;
    }
    fprintf(o, "workload,kernel,regs,local_bytes,shared_static_bytes,dynamic_shared_bytes,const_bytes,"
               "max_threads_per_block,ptx_version,grid,block,cluster,required_cluster,max_r,max_ur,max_p,max_up,"
               "static_instrs,setmaxnreg");
    for (const char *m : MARKS) fprintf(o, ",n_%s", m);
    fprintf(o, "\n");
    for (const auto &kv : kinfo) {
        const KernelInfo &k = kv.second;
        std::string smn;
        for (uint64_t v : k.setmaxnreg) smn += (smn.empty() ? "" : "/") + std::to_string(v);
        fprintf(o, "%s,%s,%d,%d,%d,%u,%d,%d,%d,%ux%ux%u,%ux%ux%u,%ux%ux%u,%dx%dx%d,%d,%d,%d,%d,%llu,%s",
                workload.c_str(), k.name.c_str(), k.regs, k.local_bytes, k.shared_static, k.dyn_shared,
                k.const_bytes, k.max_threads, k.ptx_version, k.grid[0], k.grid[1], k.grid[2], k.block[0],
                k.block[1], k.block[2], k.cluster[0], k.cluster[1], k.cluster[2], k.req_cluster[0],
                k.req_cluster[1], k.req_cluster[2], k.max_r, k.max_ur, k.max_p, k.max_up,
                (unsigned long long)k.instrs, smn.c_str());
        for (const char *m : MARKS) {
            auto it = k.marks.find(m);
            fprintf(o, ",%llu", (unsigned long long)(it == k.marks.end() ? 0 : it->second));
        }
        fprintf(o, "\n");
    }
    fclose(o);
}

void nvbit_at_term() {
    if (!kernels_out.empty()) write_kernels();
    FILE *o = fopen(out_path.c_str(), "w");
    if (!o) {
        fprintf(stderr, "kamui_sass_hist: cannot write %s\n", out_path.c_str());
        return;
    }
    fprintf(o, "workload,kernel,sass_opcode,static_count,warp_inst_executed,thread_inst_executed,"
               "thread_inst_executed_pred_true\n");
    for (const auto &kv : hist)
        fprintf(o, "%s,%s,%s,%llu,%llu,%llu,%llu\n", workload.c_str(), kv.first.first.c_str(), kv.first.second.c_str(),
                (unsigned long long)kv.second.statics, (unsigned long long)kv.second.warp,
                (unsigned long long)kv.second.thread, (unsigned long long)kv.second.pred);
    fclose(o);
    fprintf(stderr, "kamui_sass_hist: %zu kernels counted, %zu rows in %s%s\n", counted.size(), hist.size(),
            out_path.c_str(), overflow ? " (WARNING: slot table full, some instructions not counted)" : "");
}

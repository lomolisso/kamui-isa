// kamui_sass_hist: an NVBit tool that counts how often each SASS opcode executes in the kernels of a program.
//
//     LD_PRELOAD=kamui_sass_hist.so KAMUI_OUT=out.csv KAMUI_WORKLOAD=name [KAMUI_KERNELS=regex] ./program
//
// The first launch of each kernel whose name matches KAMUI_KERNELS (default: every kernel) is instrumented:
// before every SASS instruction a small device function adds one warp issue, the number of active lanes, and
// the number of active lanes whose guard predicate is true. Later launches of the same kernel run without
// instrumentation. Instructions guarded by @!PT never execute and are left out.
//
// At exit the tool writes one CSV row per kernel and SASS opcode (opcode with its modifiers, operands dropped):
//     workload,kernel,sass_opcode,static_count,warp_inst_executed,thread_inst_executed,thread_inst_executed_pred_true
// so the output is a histogram, not an instruction trace. `kernel` is the kernel's name up to the first `(` or
// `<`, plus `#` and 8 hex digits of a hash of the full mangled name, which tells apart template instances.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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
        bool want = !counted.count(f) && std::regex_search(nvbit_get_func_name(ctx, f, false), kernel_re);
        if (want) {
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

void nvbit_at_term() {
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

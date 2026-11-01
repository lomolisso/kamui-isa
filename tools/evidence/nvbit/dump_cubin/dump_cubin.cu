// dump_cubin: an NVBit tool that writes the cubin of every kernel the program launches, as the driver loaded it.
//
//     LD_PRELOAD=dump_cubin.so DUMP_CUBIN_DIR=out/ ./program
//
// For a module loaded from PTX this is the code the driver's JIT compiler produced, so comparing its SASS with
// the SASS of an offline ptxas shows whether the two compilers agree. Each kernel is written once, to
// <DUMP_CUBIN_DIR>/<kernel name>.cubin, just before its first launch. The tool does not instrument anything.
#include <stdio.h>
#include <stdlib.h>

#include <set>
#include <string>

#include "nvbit.h"
#include "nvbit_tool.h"

static std::string out_dir = ".";
static std::set<CUfunction> dumped;

void nvbit_at_init() {
    const char *d = getenv("DUMP_CUBIN_DIR");
    if (d && *d) out_dir = d;
}

void nvbit_at_cuda_event(CUcontext ctx, int is_exit, nvbit_api_cuda_t cbid, const char *name, void *params,
                         CUresult *pStatus) {
    (void)name;
    (void)pStatus;
    if (is_exit) return;
    CUfunction f = nullptr;
    if (cbid == API_CUDA_cuLaunchKernel || cbid == API_CUDA_cuLaunchKernel_ptsz)
        f = ((cuLaunchKernel_params *)params)->f;
    else if (cbid == API_CUDA_cuLaunchKernelEx || cbid == API_CUDA_cuLaunchKernelEx_ptsz)
        f = ((cuLaunchKernelEx_params *)params)->f;
    if (!f || !dumped.insert(f).second) return;
    std::string path = out_dir + "/" + nvbit_get_func_name(ctx, f, true) + ".cubin";
    if (!nvbit_dump_cubin(ctx, f, path.c_str())) fprintf(stderr, "dump_cubin: could not write %s\n", path.c_str());
}

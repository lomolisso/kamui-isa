// Device function that kamui_sass_hist inserts before every SASS instruction it counts.
#include <stdint.h>

#include "utils/utils.h"

// c points to three counters of one static instruction: warp issues, active lanes, lanes with the guard
// predicate true. One lane per warp (the first active one) updates them.
extern "C" __device__ __noinline__ void kamui_count(int pred, uint64_t c) {
    const unsigned active = __activemask();
    const unsigned predicated = __ballot_sync(active, pred);
    if (get_laneid() == __ffs(active) - 1) {
        unsigned long long *p = (unsigned long long *)c;
        atomicAdd(&p[0], 1ULL);
        atomicAdd(&p[1], (unsigned long long)__popc(active));
        atomicAdd(&p[2], (unsigned long long)__popc(predicated));
    }
}

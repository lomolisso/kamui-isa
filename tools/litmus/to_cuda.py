#!/usr/bin/env python3
"""Generate the H100 litmus kernels: tests/litmus/h100/<test>/{kernel.cu, kernel.ptx, spec.txt}.

    python tools/litmus/to_cuda.py                 # write kernel.cu and spec.txt for every test it can run
    python tools/litmus/to_cuda.py --compile       # also compile kernel.ptx with clang (dev container)
    python tools/litmus/to_cuda.py --check         # kernel.cu and spec.txt are current (no compiler needed)
    python tools/litmus/to_cuda.py --check-ptx     # kernel.ptx is current too (dev container)
    python tools/litmus/to_cuda.py --why           # the tests it cannot run, with the reason

Which tests: our own (`tests/litmus/ptx/kamui/`): the families and the hand-written tests. Each litmus thread
becomes one `asm volatile` block holding the exact PTX instructions of the test (`st.release.gpu.global.u32`,
`fence.sc.cta`, `mbarrier.arrive.release.cta.shared::cta.b64`, ...), so the instructions under test are the
ones in the litmus file, not whatever clang would choose; only ptxas compiles them further.

The kernel is the same for every test apart from the thread bodies. Every GPU thread reads its job from the
`assign` array the host fills (tools/litmus/runner.c): either "role k of instance i" or "stress". A role thread
runs litmus thread k on instance i's own locations (`locoff`, one 128-byte line per location) and writes its
registers to `res` and its SM and cluster to `place`; a stress thread reads and writes a scratch buffer. The
host decides where the roles of one instance go, following the test's placement (the CTA and cluster of each
thread in the litmus file): `same-cta` (different warps of one CTA), `same-cluster` (different CTAs of one
cluster) or `diff-cluster` (different clusters).

spec.txt tells the runner the layout: number of roles, output registers and global locations, placement, and
whether the test needs mbarrier initialization or a cluster barrier. Compilation uses the corpus flags
(tools/corpus/build.py): clang 20, sm_90a, PTX 8.7.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "corpus"))
import litmus  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "tests" / "litmus"
OUT = SUITE / "h100"
MAX_ROLES = 4
THREADS = 256  # per CTA, must match runner.c


class Unsupported(Exception):
    pass


def placement(t: litmus.Litmus) -> str:
    ctas = {(th.gpu, th.cluster, th.cta) for th in t.threads}
    if any(th.gpu != 0 for th in t.threads):
        raise Unsupported("more than one GPU")
    if len(ctas) == 1:
        return "same-cta"
    if len(ctas) != len(t.threads):
        raise Unsupported("some threads share a CTA and others do not")
    clusters = {th.cluster for th in t.threads}
    if len(clusters) == 1:
        return "same-cluster"
    if len(clusters) == len(t.threads):
        return "diff-cluster"
    raise Unsupported("mixed cluster placement")


def location_kinds(t: litmus.Litmus) -> dict[str, str]:
    """global, sbuf (shared memory, 16-byte buffer) or mbar (shared memory mbarrier)."""
    kinds: dict[str, str] = {}
    for _, i in t.instrs():
        if i.op == "mbarrier":
            kinds[i.args[0] if i.quals[0] == "arrive" else i.args[1]] = "mbar"
        elif i.op == "cp" and "bulk" in i.quals and len(i.args) == 2:
            kinds.setdefault(i.args[1], "sbuf")
            kinds.setdefault(i.args[0], "global")
        elif i.op in ("ld", "st"):
            loc = i.args[1] if i.op == "ld" else i.args[0]
            kinds.setdefault(loc, "sbuf" if "shared::cta" in i.quals else "global")
    return kinds


def _space(i: litmus.Instr) -> str:
    return "shared::cta" if "shared::cta" in i.quals else "global"


def _mem_quals(i: litmus.Instr) -> str:
    o = i.order or "weak"
    if o in ("weak", "volatile"):
        return f".{o}"
    if not i.scope:
        raise Unsupported(f"no scope on {i.text!r}")
    return f".{o}.{i.scope}"


def emit(i: litmus.Instr, ops: dict[str, str]) -> list[str]:
    """PTX lines for one instruction. `ops` maps registers and locations to asm operands (%0, %1, ...)."""
    if i.op == "ld" and len(i.args) == 2 and i.args[1] in ops:
        return [f"ld{_mem_quals(i)}.{_space(i)}.u32 {ops[i.args[0]]}, [{ops[i.args[1]]}];"]
    if i.op == "st":
        loc, v = i.args
        if not re.fullmatch(r"-?\d+", v):
            raise Unsupported(f"store of a register {i.text!r}")
        return [f"mov.u32 t, {v};", f"st{_mem_quals(i)}.{_space(i)}.u32 [{ops[loc]}], t;"]
    if i.op == "fence":
        if "proxy" in i.quals and not any(q.startswith("async") for q in i.quals):
            raise Unsupported(f"{i.text!r}")
        return [f"{i.text};"]
    if i.op == "mbarrier" and i.quals[0] == "arrive":
        return [f"mbarrier.{'.'.join(i.quals)}.shared::cta.b64 _, [{ops[i.args[0]]}];"]
    if i.op == "mbarrier" and i.quals[0] in ("test_wait", "try_wait"):
        r, b, parity = i.args
        return [f"mbarrier.{'.'.join(i.quals)}.shared::cta.b64 p, [{ops[b]}], {parity};",
                f"selp.u32 {ops[r]}, 1, 0, p;"]
    if i.op == "barrier" and i.quals[:1] == ["cluster"]:
        return [f"{i.text};"]
    if i.op == "cp" and i.quals[:2] == ["async", "bulk"]:
        if i.quals[2:] in (["commit_group"], ["wait_group"]):
            return [f"{i.text};"]
        if i.quals[2:] == ["global", "shared::cta"]:
            dst, src = i.args
            return [f"cp.async.bulk.global.shared::cta.bulk_group [{ops[dst]}], [{ops[src]}], 16;"]
    raise Unsupported(f"instruction {i.text!r}")


def generate(t: litmus.Litmus, tid: str) -> tuple[str, str]:
    if len(t.threads) > MAX_ROLES:
        raise Unsupported("more than four threads")
    if t.has_loops or t.uses_proxy and not any(i.op in ("cp", "fence") for _, i in t.instrs()):
        raise Unsupported("loops or non-async proxies")
    place = placement(t)
    kinds = location_kinds(t)
    gl = [loc for loc in kinds if kinds[loc] == "global"]
    shared = [loc for loc in kinds if kinds[loc] != "global"]
    if shared and place != "same-cta":
        raise Unsupported("shared-memory locations need all threads in one CTA")
    if len([s for s in shared if kinds[s] == "mbar"]) > 1 or len([s for s in shared if kinds[s] == "sbuf"]) > 1:
        raise Unsupported("more than one shared location of a kind")
    regs: list[tuple[int, str]] = []
    for th in t.threads:
        for i in th.instrs:
            if i.op in ("ld", "mbarrier") and i.args and re.fullmatch(r"r\d+", i.args[0]):
                if (th.tid, i.args[0]) in regs:
                    raise Unsupported(f"register P{th.tid}:{i.args[0]} written twice")
                regs.append((th.tid, i.args[0]))
    for c in litmus.cond_atoms(t.condition):
        lhs = re.sub(r"^(\d+):", r"P\1:", c.lhs)
        if ":" in lhs:
            k, r = lhs[1:].split(":")
            if (int(k), r) not in regs:
                raise Unsupported(f"condition on {lhs}, which no load writes")
        elif lhs not in gl:
            raise Unsupported(f"condition on {lhs}")
    cluster_bar = any(i.op == "barrier" for _, i in t.instrs())

    bodies = []
    for th in t.threads:
        mine = [r for k, r in regs if k == th.tid]
        used = [loc for loc in kinds if any(loc in i.args for i in th.instrs)]
        ops = {r: f"%{n}" for n, r in enumerate(mine)}
        ops.update({loc: f"%{len(mine) + n}" for n, loc in enumerate(used)})
        lines = [ln for i in th.instrs if not i.is_empty for ln in emit(i, ops)]
        asm = "\n".join(f'        "{ln}\\n\\t"' for ln in [".reg .u32 t;", ".reg .pred p;"] + lines)
        outs = ", ".join(f'"=r"(r_{r})' for r in mine)
        ins = ", ".join(f'"{"l" if kinds[loc] == "global" else "r"}"(a_{loc})' for loc in used)
        decl = "".join(f"    unsigned r_{r} = 0;\n" for r in mine)
        store = "".join(f"    out[{regs.index((th.tid, r))}] = r_{r};\n" for r in mine)
        bodies.append(
            f"// P{th.tid}: {' ; '.join(i.text for i in th.instrs if not i.is_empty)}\n"
            f"__device__ __forceinline__ void role{th.tid}(L &l, unsigned *out) {{\n"
            + "".join(f"    {'unsigned long long' if kinds[loc] == 'global' else 'unsigned'} a_{loc} = l.{loc};\n"
                      for loc in used)
            + decl
            + f'    asm volatile("{{\\n\\t"\n{asm}\n        "}}"\n        : {outs}\n        : {ins}\n'
            + '        : "memory");\n'
            + store + "}\n")

    loc_fields = "".join(f"    {'unsigned long long' if kinds[loc] == 'global' else 'unsigned'} {loc};\n"
                         for loc in kinds)
    loc_init = "".join(f"    l.{loc} = to_global(mem + lo[{gl.index(loc)}]);\n" for loc in gl)
    for loc in shared:
        arr = "mbar" if kinds[loc] == "mbar" else "sbuf"
        idx = "lslot" if kinds[loc] == "mbar" else "lslot * 4"
        loc_init += f"    l.{loc} = to_shared(&{arr}[{idx}]);\n"
    mbar = [loc for loc in shared if kinds[loc] == "mbar"]
    switch = "".join(f"    case {k}: role{k}(l, out); break;\n" for k in range(len(t.threads)))
    src = (
        f"// Generated by tools/litmus/to_cuda.py from tests/litmus/{tid}.litmus. Do not edit.\n"
        + "".join(f"// {ln}\n" for ln in t.format().splitlines())
        + KERNEL_HEAD
        + f"struct L {{\n{loc_fields}}};\n\n"
        + "\n".join(bodies)
        + KERNEL_MAIN.format(
            ngloc=max(len(gl), 1), nregs=max(len(regs), 1), nroles=len(t.threads),
            mbar_init=(f"    if (a != NONE && role == 0) {{\n"
                       f"        asm volatile(\"mbarrier.init.shared::cta.b64 [%0], 1;\" :: \"r\"(to_shared(&mbar[lslot])) : \"memory\");\n"
                       f"    }}\n    __syncthreads();\n") if mbar else "",
            cluster_bar=('        asm volatile("barrier.cluster.arrive;\\n\\tbarrier.cluster.wait;" ::: "memory");\n'
                         if cluster_bar else ""),
            loc_init=loc_init, switch=switch))
    spec = "\n".join([
        f"# Generated by tools/litmus/to_cuda.py from tests/litmus/{tid}.litmus",
        "kernel litmus",
        f"roles {len(t.threads)}",
        f"placement {place}",
        f"nregs {len(regs)}",
        f"ngloc {len(gl)}",
        f"cluster_barrier {int(cluster_bar)}",
        *[f"reg {n} P{k}:{r}" for n, (k, r) in enumerate(regs)],
        *[f"gloc {n} {loc}" for n, loc in enumerate(gl)],
    ]) + "\n"
    return src, spec


KERNEL_HEAD = r"""
// One instance of the test = one GPU thread per litmus thread ("role"). The host fills `assign`:
// bits 0-2 role, bits 3-10 the instance's slot in its CTA (for shared-memory locations), bits 11-31 the
// instance; 0xffffffff means "stress thread".
#define NONE 0xffffffffu

__device__ __forceinline__ unsigned long long to_global(unsigned *p) {
    unsigned long long g;
    asm("cvta.to.global.u64 %0, %1;" : "=l"(g) : "l"(p));
    return g;
}
__device__ __forceinline__ unsigned to_shared(const void *p) {
    unsigned long long s;
    asm("cvta.to.shared.u64 %0, %1;" : "=l"(s) : "l"(p));
    return (unsigned)s;
}
__device__ __forceinline__ unsigned sreg_smid() {
    unsigned r;
    asm volatile("mov.u32 %0, %%smid;" : "=r"(r));
    return r;
}
__device__ __forceinline__ unsigned sreg_clusterid() {
    unsigned r;
    asm volatile("mov.u32 %0, %%clusterid.x;" : "=r"(r));
    return r;
}
"""

KERNEL_MAIN = r"""
#define NGLOC {ngloc}
#define NREGS {nregs}
#define NROLES {nroles}

extern "C" __global__ void __launch_bounds__(256) litmus(unsigned *mem, unsigned *res, unsigned *place,
                                                       const unsigned *assign, const unsigned *locoff,
                                                       unsigned *scratch, unsigned scratch_mask,
                                                       unsigned stress_iters, unsigned delay_mask) {{
    __shared__ __align__(16) unsigned long long mbar[256];
    __shared__ __align__(16) unsigned sbuf[256 * 4];
    unsigned slot = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned a = assign[slot];
    unsigned role = a & 7, lslot = (a >> 3) & 255, inst = a >> 11;
{mbar_init}    if (a == NONE) {{
{cluster_bar}        unsigned h = slot * 2654435761u;
        for (unsigned k = 0; k < stress_iters; k++) {{
            h = h * 1664525u + 1013904223u;
            volatile unsigned *p = scratch + ((h >> 8) & scratch_mask);
            *p = *p + 1;
        }}
        return;
    }}
    unsigned d = (slot * 2246822519u >> 13) & delay_mask;
    for (unsigned k = 0; k < d; k++)
        asm volatile("" ::: "memory");
    const unsigned *lo = locoff + inst * NGLOC;
    unsigned *out = res + inst * NREGS;
    L l;
{loc_init}    switch (role) {{
{switch}    }}
    place[inst * NROLES + role] = (sreg_clusterid() << 8) | sreg_smid();
}}
"""



# ----------------------------------------------------------------------------------------------- PTX 8.7 tests
# The tests of tests/litmus/ptx/kamui/ptx87/ use their own kernel template (below), so that the kernels of the
# older tests stay unchanged. It runs the tests that need no distributed shared memory: every shared location
# and mbarrier belongs to the one CTA of a same-cta test; tests across CTAs use global memory only.

TX_BYTES = 16  # one transaction unit of a litmus test (one copied location) = one 16-byte bulk copy
SEM = ("weak", "relaxed", "acquire", "release", "acq_rel", "sc", "volatile")
COPS = ("ca", "cg", "cs", "lu", "cv", "wb", "wt")


def _sem87(i: litmus.Instr, default: str | None = None) -> str:
    q = i.quals
    if "mmio" in q:
        return ".mmio.relaxed.sys"
    o = next((x for x in q if x in SEM), default)
    if o is None:
        return ""
    if o in ("weak", "volatile"):
        return f".{o}"
    scope = i.scope or ("gpu" if i.op in ("atom", "red") else None)
    if scope is None:
        raise Unsupported(f"no scope on {i.text!r}")
    return f".{o}.{scope}"


def _locs87(t: litmus.Litmus):
    """name -> (kind, init): kind global, shared or mbar; init the initial value (mbar: the arrival count)."""
    init, owner = {}, {}
    for d in t.init:
        lhs, rhs = (x.strip() for x in d.split("=", 1)) if "=" in d else (d, "")
        if ":" in lhs:
            continue
        m = re.fullmatch(r"(.*?)\s*@\s*cta\s+(\d+)", rhs)
        if m:
            rhs, owner[lhs] = m.group(1).strip(), int(m.group(2))
        m = re.fullmatch(r"mbarrier\((\d*)\)", rhs)
        if m:
            if not m.group(1):
                raise Unsupported("an mbarrier initialized by the test itself")
            init[lhs] = ("mbar", int(m.group(1)))
        elif re.fullmatch(r"-?\d+", rhs) and re.fullmatch(r"\w+", lhs):
            init[lhs] = (None, int(rhs))
        else:
            raise Unsupported(f"initial state {d!r}")
    kinds = {}
    for _, i in t.instrs():
        q = i.quals
        names = [a for a in i.args if re.fullmatch(r"[A-Za-z_]\w*", a) and not re.fullmatch(r"r\d+|_", a)]
        for n in names:
            if n not in init:
                init[n] = (None, 0)
            k = init[n][0]
            if k == "mbar":
                kinds[n] = "mbar"
                continue
            if i.op == "cp":
                # copies name the destination space, then the source space: cp.async.ca.shared.global d, g
                spaces = [x for x in q if x in ("shared", "shared::cta", "shared::cluster", "global")]
                pos = i.args.index(n)
                shared = pos < len(spaces) and spaces[pos] != "global"
            else:
                shared = "shared" in q or "shared::cta" in q
            kinds[n] = "shared" if shared or kinds.get(n) == "shared" else kinds.get(n, "global")
    return kinds, {n: v for n, (_, v) in init.items()}


def _emit87(i: litmus.Instr, ops: dict[str, str], kinds) -> list[str]:
    q, a = i.quals, i.args
    sp = lambda n: "shared::cta" if kinds[n] == "shared" else "global"  # noqa: E731
    cop = "".join(f".{x}" for x in q if x in COPS)
    if i.op == "ld" and "nc" in q:
        return [f"ld.global.nc.u32 {ops[a[0]]}, [{ops[a[1]]}];"]
    if i.op == "ldu":
        return [f"ldu.global.u32 {ops[a[0]]}, [{ops[a[1]]}];"]
    if i.op == "ld" and len(a) == 2 and a[1] in ops and not any(re.fullmatch(r"v\d", x) for x in q):
        return [f"ld{_sem87(i, 'weak')}.{sp(a[1])}{cop}.u32 {ops[a[0]]}, [{ops[a[1]]}];"]
    if i.op == "st" and len(a) == 2 and "async" not in q and not any(re.fullmatch(r"v\d", x) for x in q):
        if not re.fullmatch(r"-?\d+", a[1]):
            raise Unsupported(f"store of a register {i.text!r}")
        return [f"mov.u32 t, {a[1]};", f"st{_sem87(i, 'weak')}.{sp(a[0])}{cop}.u32 [{ops[a[0]]}], t;"]
    if i.op in ("atom", "red") and "async" not in q and "b128" not in q and not any(re.fullmatch(r"v\d", x) for x in q):
        op = next((x for x in q if x in ("add", "inc", "dec", "min", "max", "and", "or", "xor", "exch", "cas")), None)
        if op is None:
            raise Unsupported(f"{i.text!r}")
        ty = "b32" if op in ("and", "or", "xor", "exch", "cas") else "u32"
        args = list(a)
        dst = None if i.op == "red" else ops[args.pop(0)]
        loc = args.pop(0)
        if not all(re.fullmatch(r"-?\d+", v) for v in args):
            raise Unsupported(f"register operand {i.text!r}")
        head = f"{i.op}{_sem87(i, 'relaxed')}.{sp(loc)}.{op}.{ty}"
        return [f"{head} {dst + ', ' if dst else ''}[{ops[loc]}], {', '.join(args)};"]
    if i.op == "fence" and not ({"tensormap::generic"} & set(q)):
        if "proxy" in q and not any(x.startswith("async") for x in q):
            raise Unsupported(f"{i.text!r}")
        return [f"{i.text};"]
    if i.op == "barrier" and q[:1] == ["cluster"]:
        return [f"{i.text};"]
    if i.op == "mbarrier":
        kind = q[0]
        sem = next((x for x in q if x in ("release", "relaxed", "acquire")), None)
        scope = next((x for x in q if x in ("cta", "cluster")), "cta")
        if "shared::cluster" in q or scope != "cta":
            raise Unsupported(f"remote or cluster-scope mbarrier {i.text!r}")
        if kind in ("arrive", "arrive_drop"):
            if a[0] not in kinds:
                raise Unsupported(f"arrive with a state register {i.text!r}")
            sub = ".expect_tx" if q[1:2] == ["expect_tx"] else ""
            extra = f", {int(a[1]) * TX_BYTES}" if sub else (f", {a[1]}" if len(a) > 1 else "")
            return [f"mbarrier.{kind}{sub}.{sem or 'release'}.cta.shared::cta.b64 _, [{ops[a[0]]}]{extra};"]
        if kind in ("expect_tx", "complete_tx"):
            return [f"mbarrier.{kind}.relaxed.cta.shared::cta.b64 [{ops[a[0]]}], {int(a[1]) * TX_BYTES};"]
        if kind in ("test_wait", "try_wait") and "parity" in q:
            r, b, parity = a[:3]
            return [f"mbarrier.{kind}.parity.{sem or 'acquire'}.cta.shared::cta.b64 p, [{ops[b]}], {parity};",
                    f"selp.u32 {ops[r]}, 1, 0, p;"]
        raise Unsupported(f"{i.text!r}")
    if i.op == "cp":
        rest = q[1:]
        if q[0] == "async" and rest in (["commit_group"], ["wait_group"], ["wait_all"], ["bulk", "commit_group"],
                                        ["bulk", "wait_group"], ["bulk", "wait_group", "read"]):
            return [f"{i.text};"]
        if q[0] == "async" and rest[:2] == ["mbarrier", "arrive"]:
            return [f"cp.async.mbarrier.arrive{'.noinc' if 'noinc' in q else ''}.shared::cta.b64 [{ops[a[0]]}];"]
        if q[0] == "async" and rest[:1] in (["ca"], ["cg"]):
            return [f"cp.async.ca.shared.global [{ops[a[0]]}], [{ops[a[1]]}], 4;"]
        if q[0] == "async" and rest == ["bulk", "global", "shared::cta", "bulk_group"]:
            return [f"cp.async.bulk.global.shared::cta.bulk_group [{ops[a[0]]}], [{ops[a[1]]}], {TX_BYTES};"]
        if q[0] == "async" and rest == ["bulk", "shared::cluster", "global", "mbarrier::complete_tx::bytes"]:
            return [f"cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes [{ops[a[0]]}], [{ops[a[1]]}], "
                    f"{TX_BYTES}, [{ops[a[2]]}];"]
        if q[:2] == ["reduce", "async"] and q[2:] == ["bulk", "global", "shared::cta", "bulk_group", "add", "u32"]:
            return [f"cp.reduce.async.bulk.global.shared::cta.bulk_group.add.u32 [{ops[a[0]]}], [{ops[a[1]]}], "
                    f"{TX_BYTES};"]
    raise Unsupported(f"instruction {i.text!r}")


def generate87(t: litmus.Litmus, tid: str) -> tuple[str, str]:
    if len(t.threads) > MAX_ROLES:
        raise Unsupported("more than four threads")
    if t.has_loops or any(th.grid is not None for th in t.threads):
        raise Unsupported("loops or grids")
    place = placement(t)
    kinds, init = _locs87(t)
    gl = [n for n in kinds if kinds[n] == "global"]
    sh = [n for n in kinds if kinds[n] == "shared"]
    mb = [n for n in kinds if kinds[n] == "mbar"]
    if (sh or mb) and place != "same-cta":
        raise Unsupported("shared memory across CTAs (no distributed shared memory in the harness)")
    if len(sh) > 4 or len(mb) > 2:
        raise Unsupported("too many shared locations")
    if any(v != 0 for n, v in init.items() if n in gl) and place != "same-cta":
        raise Unsupported("non-zero initial values across CTAs")
    regs: list[tuple[int, str]] = []
    for th in t.threads:
        for i in th.instrs:
            if i.is_empty:
                continue
            writes = i.op in ("ld", "ldu", "atom") or (i.op == "mbarrier" and i.quals[0] in ("test_wait", "try_wait"))
            if writes and i.args and re.fullmatch(r"r\d+", i.args[0]):
                if (th.tid, i.args[0]) in regs:
                    raise Unsupported(f"register P{th.tid}:{i.args[0]} written twice")
                regs.append((th.tid, i.args[0]))
    for c in litmus.cond_atoms(t.condition):
        for side in (c.lhs, c.rhs):
            side = re.sub(r"^(\d+):", r"P\1:", side)
            if re.fullmatch(r"-?\d+", side):
                continue
            if ":" in side:
                k, r = side[1:].split(":")
                if (int(k), r) not in regs:
                    raise Unsupported(f"condition on {side}, which no load writes")
            elif side not in gl:
                raise Unsupported(f"condition on {side}")
    cluster_bar = any(i.op == "barrier" for _, i in t.instrs())
    bodies = []
    for th in t.threads:
        mine = [r for k, r in regs if k == th.tid]
        used = [n for n in kinds if any(n in i.args for i in th.instrs)]
        ops = {r: f"%{n}" for n, r in enumerate(mine)}
        ops.update({n: f"%{len(mine) + k}" for k, n in enumerate(used)})
        lines = [ln for i in th.instrs if not i.is_empty for ln in _emit87(i, ops, kinds)]
        asm = "\n".join(f'        "{ln}\\n\\t"' for ln in [".reg .u32 t;", ".reg .pred p;"] + lines)
        outs = ", ".join(f'"=r"(r_{r})' for r in mine)
        ins = ", ".join(f'"{"l" if kinds[n] == "global" else "r"}"(a_{n})' for n in used)
        bodies.append(
            f"// P{th.tid}: {' ; '.join(i.text for i in th.instrs if not i.is_empty)}\n"
            f"__device__ __forceinline__ void role{th.tid}(L &l, unsigned *out) {{\n"
            + "".join(f"    {'unsigned long long' if kinds[n] == 'global' else 'unsigned'} a_{n} = l.{n};\n" for n in used)
            + "".join(f"    unsigned r_{r} = 0;\n" for r in mine)
            + f'    asm volatile("{{\\n\\t"\n{asm}\n        "}}"\n        : {outs}\n        : {ins}\n        : "memory");\n'
            + "".join(f"    out[{regs.index((th.tid, r))}] = r_{r};\n" for r in mine) + "}\n")
    fields = "".join(f"    {'unsigned long long' if kinds[n] == 'global' else 'unsigned'} {n};\n" for n in kinds)
    loc_init = "".join(f"    l.{n} = to_global(mem + lo[{gl.index(n)}]);\n" for n in gl)
    loc_init += "".join(f"    l.{n} = to_shared(&sbuf[({k} * 256 + lslot) * 4]);\n" for k, n in enumerate(sh))
    loc_init += "".join(f"    l.{n} = to_shared(&mbar[{k} * 256 + lslot]);\n" for k, n in enumerate(mb))
    setup = ""
    if place == "same-cta":
        setup = "    if (a != NONE && role == 0) {\n        const unsigned *lo = locoff + inst * NGLOC;\n"
        setup += "".join(f"        mem[lo[{gl.index(n)}]] = {init[n]}u;\n" for n in gl if init[n])
        setup += "".join(f"        sbuf[({k} * 256 + lslot) * 4] = {init[n]}u;\n" for k, n in enumerate(sh))
        setup += "".join(f'        asm volatile("mbarrier.init.shared::cta.b64 [%0], {init[n]};" :: "r"(to_shared(&mbar[{k} * 256 + lslot])) : "memory");\n'
                         for k, n in enumerate(mb))
        setup += '        asm volatile("fence.proxy.async.shared::cta;" ::: "memory");\n    }\n    __syncthreads();\n'
    src = (f"// Generated by tools/litmus/to_cuda.py from tests/litmus/{tid}.litmus. Do not edit.\n"
           + "".join(f"// {ln}\n" for ln in t.format().splitlines()) + KERNEL_HEAD
           + f"struct L {{\n{fields}}};\n\n" + "\n".join(bodies)
           + KERNEL_MAIN87.format(ngloc=max(len(gl), 1), nregs=max(len(regs), 1), nroles=len(t.threads), setup=setup,
                                  cluster_bar=('        asm volatile("barrier.cluster.arrive;\\n\\tbarrier.cluster.wait;" ::: "memory");\n'
                                               if cluster_bar else ""),
                                  loc_init=loc_init,
                                  switch="".join(f"    case {k}: role{k}(l, out); break;\n" for k in range(len(t.threads)))))
    spec = "\n".join([f"# Generated by tools/litmus/to_cuda.py from tests/litmus/{tid}.litmus", "kernel litmus",
                      f"roles {len(t.threads)}", f"placement {place}", f"nregs {len(regs)}", f"ngloc {len(gl)}",
                      f"cluster_barrier {int(cluster_bar)}",
                      *[f"reg {n} P{k}:{r}" for n, (k, r) in enumerate(regs)],
                      *[f"gloc {n} {loc}" for n, loc in enumerate(gl)]]) + "\n"
    return src, spec


KERNEL_MAIN87 = r"""
#define NGLOC {ngloc}
#define NREGS {nregs}
#define NROLES {nroles}

extern "C" __global__ void __launch_bounds__(256) litmus(unsigned *mem, unsigned *res, unsigned *place,
                                                       const unsigned *assign, const unsigned *locoff,
                                                       unsigned *scratch, unsigned scratch_mask,
                                                       unsigned stress_iters, unsigned delay_mask) {{
    __shared__ __align__(16) unsigned long long mbar[2 * 256];
    __shared__ __align__(16) unsigned sbuf[4 * 256 * 4];
    unsigned slot = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned a = assign[slot];
    unsigned role = a & 7, lslot = (a >> 3) & 255, inst = a >> 11;
{setup}    if (a == NONE) {{
{cluster_bar}        unsigned h = slot * 2654435761u;
        for (unsigned k = 0; k < stress_iters; k++) {{
            h = h * 1664525u + 1013904223u;
            volatile unsigned *p = scratch + ((h >> 8) & scratch_mask);
            *p = *p + 1;
        }}
        return;
    }}
    unsigned d = (slot * 2246822519u >> 13) & delay_mask;
    for (unsigned k = 0; k < d; k++)
        asm volatile("" ::: "memory");
    const unsigned *lo = locoff + inst * NGLOC;
    unsigned *out = res + inst * NREGS;
    L l;
{loc_init}    switch (role) {{
{switch}    }}
    place[inst * NROLES + role] = (sreg_clusterid() << 8) | sreg_smid();
}}
"""


def tests() -> list[Path]:
    return sorted((SUITE / "ptx" / "kamui").rglob("*.litmus"))


def test_id(p: Path) -> str:
    return p.relative_to(SUITE).with_suffix("").as_posix()


def out_dir(tid: str) -> Path:
    return OUT / tid.removeprefix("ptx/")


def generate_all() -> tuple[dict[Path, str], dict[str, str]]:
    files, skipped = {}, {}
    for p in tests():
        tid = test_id(p)
        try:
            gen = generate87 if tid.startswith("ptx/kamui/ptx87/") else generate
            src, spec = gen(litmus.load(p), tid)
        except Unsupported as e:
            skipped[tid] = str(e)
            continue
        d = out_dir(tid)
        files[d / "kernel.cu"] = src
        files[d / "spec.txt"] = spec
    return files, skipped


def compile_ptx(cu: Path) -> str:
    import build  # tools/corpus/build.py: the corpus compiler flags

    cmd = [build.CLANG, *build.COMMON_FLAGS, f"-fdebug-prefix-map={cu.parent}=.", "-o", "-", cu.name]
    p = subprocess.run(cmd, cwd=cu.parent, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{cu}: {p.stderr[-2000:]}")
    return p.stdout


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compile", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--check-ptx", action="store_true")
    ap.add_argument("--why", action="store_true")
    a = ap.parse_args()
    files, skipped = generate_all()
    if a.why:
        for tid, why in sorted(skipped.items()):
            print(f"{tid}: {why}")
    if a.check or a.check_ptx:
        bad = [p for p, s in files.items() if not p.exists() or p.read_text() != s]
        dirs = {p.parent for p in files}
        extra = sorted(d for d in {p.parent for p in OUT.rglob("spec.txt")} if d not in dirs) if OUT.exists() else []
        if a.check_ptx:
            for d in sorted(dirs):
                ptx = d / "kernel.ptx"
                if not ptx.exists() or ptx.read_text() != compile_ptx(d / "kernel.cu"):
                    bad.append(ptx)
        for p in bad + extra:
            print(f"stale, missing or orphaned: {p.relative_to(ROOT)}")
        print(f"{len(dirs)} kernels, {len(bad)} stale, {len(extra)} orphaned")
        return 1 if bad or extra else 0
    for p, s in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(s)
    if a.compile:
        for d in sorted({p.parent for p in files}):
            (d / "kernel.ptx").write_text(compile_ptx(d / "kernel.cu"))
    print(f"wrote {len(files) // 2} kernels, skipped {len(skipped)} tests", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

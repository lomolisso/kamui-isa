#!/usr/bin/env python3
"""Generate the H100 litmus kernels: tests/litmus/h100/<test>/{kernel.cu, kernel.ptx, spec.txt}.

    python tools/litmus/to_cuda.py                 # write kernel.cu and spec.txt for every test it can run
    python tools/litmus/to_cuda.py --compile       # also compile kernel.ptx with clang (dev container)
    python tools/litmus/to_cuda.py --check         # kernel.cu and spec.txt are current (no compiler needed)
    python tools/litmus/to_cuda.py --check-ptx     # kernel.ptx is current too (dev container)
    python tools/litmus/to_cuda.py --why           # the tests it cannot run, with the reason

Which tests: every test of `tests/litmus/ptx/` the harness can run (`--why` lists the others with the reason).
The families and the hand-written tests use the first kernel template; the PTX 8.7 tests and the imported tests
(Dat3M, mixedproxy) the second (`generate87`), which also handles CTA barriers (`bar.sync id, n` and Dat3M's
`bar.cta.sync instance[, id[, quorum]]`), threads that share some CTAs but not others (placement `mixed`),
register stores and non-zero initial values across CTAs. Never run: accesses through texture, surface or
constant proxy aliases, more than one GPU, loops, and barriers that cannot complete. Each litmus thread
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
ROLE_THREADS = 192  # per CTA, must match runner.c
THREADS = 256  # per CTA, must match runner.c


class Unsupported(Exception):
    pass


def placement(t: litmus.Litmus, mixed: bool = False) -> str:
    ctas = {(th.gpu, th.cluster, th.cta) for th in t.threads}
    if any(th.gpu != 0 for th in t.threads):
        raise Unsupported("more than one GPU")
    if len(ctas) == 1:
        return "same-cta"
    if len(ctas) != len(t.threads):
        if mixed and len({th.cluster for th in t.threads}) == 1:
            return "mixed"
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


def cta_groups(t: litmus.Litmus) -> list[int]:
    """The CTA of each thread as an index 0, 1, ... in order of first appearance."""
    seen: dict = {}
    return [seen.setdefault((th.cluster, th.cta), len(seen)) for th in t.threads]


def reg_init(t: litmus.Litmus) -> dict[tuple[int, str], int]:
    """(thread, register) -> initial value, from declarators such as P0:r2=1."""
    out = {}
    for d in t.init:
        m = re.fullmatch(r"P?(\d+):(r\d+)\s*=\s*(-?\d+)", d.strip())
        if m:
            out[(int(m.group(1)), m.group(2))] = int(m.group(3))
    return out


def _locs87(t: litmus.Litmus):
    """name -> (kind, init): kind global, shared or mbar; init the initial value (mbar: the arrival count)."""
    init, owner, aliases = {}, {}, set()
    for d in t.init:
        lhs, rhs = (x.strip() for x in d.split("=", 1)) if "=" in d else (d, "")
        if ":" in lhs:
            continue
        m = re.fullmatch(r"(\w+)\s*@\s*\w+\s+aliases\s+\w+", d.strip())
        if m:
            # a proxy alias declaration; harmless if the test never uses the alias
            aliases.add(m.group(1))
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
        if i.op == "bar":
            names = []
        if set(names) & aliases:
            raise Unsupported(f"access through a proxy alias {i.text!r}")
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
                shared = "shared" in q or "shared::cta" in q or "shared::cluster" in q
            kinds[n] = "shared" if shared or kinds.get(n) == "shared" else kinds.get(n, "global")
    _locs87.owner = owner
    return kinds, {n: v for n, (_, v) in init.items()}


def _emit87(i: litmus.Instr, ops: dict[str, str], kinds, tx: int = TX_BYTES) -> list[str]:
    q, a = i.quals, i.args
    remote = "shared::cluster" in q
    # a shared location through the cluster window: its shared::cluster address (mapa), which may be in another CTA
    sp = lambda n: ("shared::cluster" if remote and n + "#cl" in ops else "shared::cta") \
        if kinds[n] != "global" else "global"  # noqa: E731
    ad = lambda n: ops.get(n + "#cl", ops[n]) if remote and kinds[n] != "global" else ops[n]  # noqa: E731
    cop = "".join(f".{x}" for x in q if x in COPS)
    # eviction priorities and the L2 cache policy are hints (D27); a policy operand comes from createpolicy
    cop += "".join(f".{x}" for x in q if x.startswith("L1::") or x in ("L2::64B", "L2::128B", "L2::256B"))
    pol = "L2::cache_hint" in q
    if pol:
        cop += ".L2::cache_hint"
    wrap = (lambda ls: ["{", ".reg .b64 pol;", "createpolicy.fractional.L2::evict_last.b64 pol, 1.0;", *ls, "}"]) \
        if pol else (lambda ls: ls)  # noqa: E731
    tail = ", pol" if pol else ""
    if i.op in ("prefetch", "prefetchu") and len(a) == 1 and kinds.get(a[0]) == "global":
        return [f"{i.op}{''.join('.' + x for x in q)} [{ops[a[0]]}];"]
    if i.op == "applypriority" and len(a) == 1 and kinds.get(a[0]) == "global":
        # the operand must be a 128-byte aligned line: the line holding the location
        return ["{", ".reg .b64 al;", f"and.b64 al, {ops[a[0]]}, -128;",
                f"applypriority{''.join('.' + x for x in q)} [al], 128;", "}"]
    if i.op == "cp" and q[:3] == ["async", "bulk", "prefetch"] and len(a) == 1 and kinds.get(a[0]) == "global":
        return ["{", ".reg .b64 al;", f"and.b64 al, {ops[a[0]]}, -16;",
                f"cp.async.bulk.prefetch{''.join('.' + x for x in q[3:])} [al], 16;", "}"]
    if i.op == "ld" and "nc" in q:
        return [f"ld.global.nc.u32 {ops[a[0]]}, [{ops[a[1]]}];"]
    if i.op == "ld" and not q and len(a) == 2 and re.fullmatch(r"-?\d+", a[1]):
        return [f"mov.u32 {ops[a[0]]}, {a[1]};"]  # a register move in the litmus dialect: ld r0, 1
    if i.op == "ldu":
        return [f"ldu.global.u32 {ops[a[0]]}, [{ops[a[1]]}];"]
    if i.op == "ld" and len(a) == 2 and a[1] in ops and not any(re.fullmatch(r"v\d", x) for x in q):
        return wrap([f"ld{_sem87(i, 'weak')}.{sp(a[1])}{cop}.u32 {ops[a[0]]}, [{ad(a[1])}]{tail};"])
    if i.op == "st" and len(a) == 2 and "async" not in q and not any(re.fullmatch(r"v\d", x) for x in q):
        val = a[1] if re.fullmatch(r"-?\d+", a[1]) else ops.get(a[1])
        if val is None:
            raise Unsupported(f"store of a register {i.text!r}")
        return wrap([f"mov.u32 t, {val};", f"st{_sem87(i, 'weak')}.{sp(a[0])}{cop}.u32 [{ad(a[0])}], t{tail};"])
    if i.op in ("atom", "red") and "async" not in q and "b128" not in q and not any(re.fullmatch(r"v\d", x) for x in q):
        op = next((x for x in q if x in ("add", "sub", "inc", "dec", "min", "max", "and", "or", "xor", "exch", "cas")),
                  None)
        if op is None:
            raise Unsupported(f"{i.text!r}")
        ty = "b32" if op in ("and", "or", "xor", "exch", "cas") else "u32"
        args = list(a)
        dst = None if i.op == "red" else ops[args.pop(0)]
        loc = args.pop(0)
        if not all(re.fullmatch(r"-?\d+", v) or v in ops for v in args):
            raise Unsupported(f"register operand {i.text!r}")
        if op == "sub":  # PTX has no atom.sub: add the negated constant
            if not all(re.fullmatch(r"-?\d+", v) for v in args):
                raise Unsupported(f"register operand {i.text!r}")
            op, args = "add", [str(-int(v)) for v in args]
        args = [ops.get(v, v) for v in args]
        if i.op == "red" and ({"acquire", "acq_rel", "sc"} & set(q)):
            raise Unsupported(f"red with an acquire order is not PTX {i.text!r}")
        head = f"{i.op}{_sem87(i, 'relaxed')}.{sp(loc)}.{op}.{ty}"
        return [f"{head} {dst + ', ' if dst else ''}[{ad(loc)}], {', '.join(args)};"]
    if i.op == "st" and q[:1] == ["async"] and remote and "global" not in q:
        d, v, b = a
        sem = _sem87(i) if any(x in SEM for x in q) else ""
        return [f"st.async{sem}.shared::cluster.mbarrier::complete_tx::bytes.b32 [{ad(d)}], {v}, [{ad(b)}];"]
    if i.op == "red" and q[:1] == ["async"] and remote and "add" in q:
        d, v, b = a
        return [f"red.async.relaxed.cluster.shared::cluster.mbarrier::complete_tx::bytes.add.u32 "
                f"[{ad(d)}], {v}, [{ad(b)}];"]
    if i.op == "fence" and not ({"tensormap::generic"} & set(q)):
        if "proxy" in q and not any(x.startswith("async") or x == "alias" for x in q):
            raise Unsupported(f"{i.text!r}")
        return [f"{i.text};"]
    if i.op == "barrier" and q[:1] == ["cluster"]:
        return [f"{i.text};"]
    if i.op == "mbarrier":
        kind = q[0]
        sem = next((x for x in q if x in ("release", "relaxed", "acquire")), None)
        scope = next((x for x in q if x in ("cta", "cluster")), "cta")
        win = "shared::cluster" if a and a[0] + "#cl" in ops and remote else "shared::cta"
        if kind in ("arrive", "arrive_drop"):
            if a[0] not in kinds:
                raise Unsupported(f"arrive with a state register {i.text!r}")
            sub = ".expect_tx" if q[1:2] == ["expect_tx"] else ""
            extra = f", {int(a[1]) * tx}" if sub else (f", {a[1]}" if len(a) > 1 else "")
            return [f"mbarrier.{kind}{sub}.{sem or 'release'}.{scope}.{win}.b64 _, [{ad(a[0])}]{extra};"]
        if kind in ("expect_tx", "complete_tx"):
            return [f"mbarrier.{kind}.relaxed.{scope}.{win}.b64 [{ad(a[0])}], {int(a[1]) * tx};"]
        if kind in ("test_wait", "try_wait") and "parity" in q and not remote:
            r, b, parity = a[:3]
            return [f"mbarrier.{kind}.parity.{sem or 'acquire'}.{scope}.shared::cta.b64 p, [{ops[b]}], {parity};",
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
            cl = lambda n: ops.get(n + "#cl", ops[n])  # noqa: E731
            return [f"cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes [{cl(a[0])}], [{ops[a[1]]}], "
                    f"{TX_BYTES}, [{cl(a[2])}];"]
        if q[:2] == ["reduce", "async"] and q[2:] == ["bulk", "global", "shared::cta", "bulk_group", "add", "u32"]:
            return [f"cp.reduce.async.bulk.global.shared::cta.bulk_group.add.u32 [{ops[a[0]]}], [{ops[a[1]]}], "
                    f"{TX_BYTES};"]
    raise Unsupported(f"instruction {i.text!r}")


def _barriers(t: litmus.Litmus, groups: list[int], rinit) -> tuple[dict[int, list[str]], int]:
    """CTA barriers: the PTX form bar.sync id, count and Dat3M's bar.cta.sync instance[, id[, quorum]].

    Each barrier of the test becomes a hardware barrier `gb + k` (gb: the first barrier id of the instance group,
    an input of the kernel). Every role of an instance is one warp, so the thread count is 32 per role that takes
    part in the same CTA. Barriers that cannot complete on the GPU (a count larger or smaller than the number of
    roles that arrive) are not run. Returns the code for each barrier instruction (keyed by id(instr)) and the
    number of hardware barriers per instance group."""
    keys: dict = {}
    uses = []
    for th in t.threads:
        for i in th.instrs:
            if i.op != "bar":
                continue
            q, a = i.quals, i.args
            if q[:1] == ["warp"]:
                raise Unsupported(f"bar.warp.sync between roles in different warps {i.text!r}")
            if q[:1] == ["cta"]:  # Dat3M: bar.cta.sync|arrive instance[, id[, quorum]]
                mode, inst = q[1], a[0]
                ids = a[1] if len(a) > 1 else None
                if ids is not None and not re.fullmatch(r"\d+", ids):
                    if (th.tid, ids) not in rinit:
                        raise Unsupported(f"barrier id from a register written by the test {i.text!r}")
                    ids = str(rinit[(th.tid, ids)])
                key, want = (inst, ids), (int(a[2]) if len(a) > 2 else None)
            elif q[:1] in (["sync"], ["arrive"]) and len(a) == 2:  # PTX: bar.sync id, thread count
                mode, key, want = q[0], ("ptx", a[0]), int(a[1])
            elif q[:1] == ["sync"] and len(a) == 1:  # bar.sync id: every thread of the CTA
                mode, key, want = "sync", ("ptx", a[0]), groups.count(groups[th.tid])
            else:
                raise Unsupported(f"{i.text!r}")
            keys.setdefault(key, set()).add(th.tid)
            uses.append((i, th.tid, key, mode, want))
    # the barriers must complete: simulate the arrivals (Dat3M has tests that deadlock, for example
    # PC-bar-sync-sync-3, where two threads wait at two barriers in opposite orders)
    ops = {th.tid: [(key, mode) for _, k_, key, mode, _ in uses if k_ == th.tid] for th in t.threads}
    need = {(key, g): sum(1 for k in keys[key] if groups[k] == g) for key in keys for g in set(groups)}
    pos, gen, arrived, waiting = dict.fromkeys(ops, 0), {}, {}, {}
    progress = True
    while progress:
        progress = False
        for k, seq in ops.items():
            while pos[k] < len(seq):
                key, mode = seq[pos[k]]
                slot = (key, groups[k])
                if k not in waiting:
                    gen_k = gen.setdefault((k, key), 0)
                    gen[(k, key)] += 1
                    arrived[(slot, gen_k)] = arrived.get((slot, gen_k), 0) + 1
                    waiting[k] = (slot, gen_k)
                if mode == "sync" and arrived[waiting[k]] < need[slot]:
                    break
                del waiting[k]
                pos[k] += 1
                progress = True
    if any(pos[k] < len(seq) for k, seq in ops.items()):
        raise Unsupported("the barriers of the test deadlock")
    code = {}
    order = sorted(keys, key=str)
    for i, tid_, key, mode, want in uses:
        parts = keys[key]
        if want is not None and (want != len(parts) or len({groups[k] for k in parts}) != 1):
            raise Unsupported(f"a barrier that cannot complete as the test intends on the GPU {i.text!r}")
        n = sum(1 for k in parts if groups[k] == groups[tid_])
        code[id(i)] = [f"add.u32 bid, %gb, {order.index(key)};",
                       f"barrier.{'arrive' if mode == 'arrive' else 'sync'} bid, {32 * n};"]
    return code, len(order)


def generate87(t: litmus.Litmus, tid: str) -> tuple[str, str]:
    if len(t.threads) > MAX_ROLES:
        raise Unsupported("more than four threads")
    if t.has_loops or any(th.grid is not None for th in t.threads):
        raise Unsupported("loops or grids")
    place = placement(t, mixed=True)
    groups = cta_groups(t)
    rinit = reg_init(t)
    kinds, init = _locs87(t)
    barcode, nbar = _barriers(t, groups, rinit)
    if nbar:
        per_cta = max(groups.count(g) for g in set(groups))
        ninst = (ROLE_THREADS // 32) // per_cta if place in ("same-cta", "mixed") else 1
        if 1 + ninst * nbar > 16:
            raise Unsupported("more than 15 hardware barriers per CTA")
    gl = [n for n in kinds if kinds[n] == "global"]
    sh = [n for n in kinds if kinds[n] == "shared"]
    mb = [n for n in kinds if kinds[n] == "mbar"]
    # Distributed shared memory: a shared location or mbarrier lives in one CTA of the cluster (`@cta N`, else the
    # CTA of the first thread that names it); that CTA initializes it, other CTAs reach it through its
    # shared::cluster address (mapa). The CTA of test group g is CTA rank g of the cluster (spec `dsmem 1`).
    dsmem = bool(sh or mb) and place != "same-cta"
    owner: dict[str, int] = {}
    if sh or mb:
        if place == "diff-cluster":
            raise Unsupported("shared memory across clusters")
        if any({"multicast::cluster", "tensor"} & set(i.quals) for _, i in t.instrs()):
            raise Unsupported("multicast and tensor copies (need equal offsets in several CTAs or a tensor map)")
        cta_group = {th.cta: groups[th.tid] for th in t.threads}
        for n in sh + mb:
            o = _locs87.owner.get(n)
            if o is not None and o not in cta_group:
                raise Unsupported(f"{n} lives in a CTA that runs no thread")
            owner[n] = cta_group[o] if o is not None else \
                next(groups[th.tid] for th in t.threads if any(n in i.args for i in th.instrs))
        for th in t.threads:
            for i in th.instrs:
                for n in set(i.args) & set(owner):
                    if groups[th.tid] != owner[n] and "shared::cluster" not in i.quals:
                        raise Unsupported(f"{n} used from another CTA outside the cluster window {i.text!r}")
    asyncst = any(i.op in ("st", "red") and i.quals[:1] == ["async"] for _, i in t.instrs())
    bulk = any(i.op == "cp" and "bulk" in i.quals for _, i in t.instrs())
    if asyncst and bulk:
        raise Unsupported("st.async or red.async together with bulk copies (two transaction sizes)")
    tx = 4 if asyncst else TX_BYTES
    if len(sh) > 4 or len(mb) > 2:
        raise Unsupported("too many shared locations")
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
    warp_bar = cluster_bar or bool(nbar) or dsmem
    bodies = []
    for th in t.threads:
        mine = [r for k, r in regs if k == th.tid]
        used = [n for n in kinds if any(n in i.args for i in th.instrs)]
        uses_bar = any(id(i) in barcode for i in th.instrs)
        ops = {r: f"%{n}" for n, r in enumerate(mine)}
        ops.update({n: f"%{len(mine) + k}" for k, n in enumerate(used)})
        # shared locations through the cluster window: their shared::cluster addresses (in the owner CTA)
        clw = [n for n in used if n in owner and dsmem]
        base = len(mine) + len(used) + (1 if uses_bar else 0)
        ops.update({n + "#cl": f"%{base + k}" for k, n in enumerate(clw)})
        # registers no load writes (initial values such as P0:r2=1): asm-local registers
        local = sorted({x for i in th.instrs for x in i.args if re.fullmatch(r"r\d+", x)} - set(mine))
        ops.update({r: f"q{r}" for r in local})
        pre = [f".reg .u32 q{r};" for r in local] + [f"mov.u32 q{r}, {rinit.get((th.tid, r), 0)};" for r in local]
        gb_op = f"%{len(mine) + len(used)}"
        if uses_bar:
            pre.append(".reg .u32 bid;")
        lines = [ln.replace("%gb", gb_op) for i in th.instrs if not i.is_empty
                 for ln in (barcode.get(id(i)) or _emit87(i, ops, kinds, tx))]
        asm = "\n".join(f'        "{ln}\\n\\t"' for ln in [".reg .u32 t;", ".reg .pred p;"] + pre + lines)
        outs = ", ".join(f'"=r"(r_{r})' for r in mine)
        ins = ", ".join([f'"{"l" if kinds[n] == "global" else "r"}"(a_{n})' for n in used]
                        + (['"r"(l.gb)'] if uses_bar else []) + [f'"r"(c_{n})' for n in clw])
        mapa = "".join(f"    unsigned c_{n};\n"
                       f'    asm("mapa.shared::cluster.u32 %0, %1, {owner[n] if dsmem else 0};" : "=r"(c_{n}) : "r"(a_{n}));\n'
                       if dsmem else f"    unsigned c_{n} = a_{n};\n" for n in clw)
        bodies.append(
            f"// P{th.tid}: {' ; '.join(i.text for i in th.instrs if not i.is_empty)}\n"
            f"__device__ __forceinline__ void role{th.tid}(L &l, unsigned *out) {{\n"
            + "".join(f"    {'unsigned long long' if kinds[n] == 'global' else 'unsigned'} a_{n} = l.{n};\n" for n in used)
            + "".join(f"    unsigned r_{r} = 0;\n" for r in mine) + mapa
            + f'    asm volatile("{{\\n\\t"\n{asm}\n        "}}"\n        : {outs}\n        : {ins}\n        : "memory");\n'
            + "".join(f"    out[{regs.index((th.tid, r))}] = r_{r};\n" for r in mine) + "}\n")
    fields = "".join(f"    {'unsigned long long' if kinds[n] == 'global' else 'unsigned'} {n};\n" for n in kinds)
    if nbar:
        fields += "    unsigned gb;\n"
    loc_init = "".join(f"    l.{n} = to_global(mem + lo[{gl.index(n)}]);\n" for n in gl)
    loc_init += "".join(f"    l.{n} = to_shared(&sbuf[({k} * 256 + lslot) * 4]);\n" for k, n in enumerate(sh))
    loc_init += "".join(f"    l.{n} = to_shared(&mbar[{k} * 256 + lslot]);\n" for k, n in enumerate(mb))
    if nbar:
        # one set of hardware barriers per instance group of a CTA (lslot / 32); one role per CTA needs only one
        loc_init += (f"    l.gb = 1 + (lslot >> 5) * {nbar};\n" if place in ("same-cta", "mixed") else "    l.gb = 1;\n")
    setup = ""
    if place == "same-cta":
        setup = "    if (a != NONE && role == 0) {\n        const unsigned *lo = locoff + inst * NGLOC;\n"
        setup += "".join(f"        mem[lo[{gl.index(n)}]] = {init[n]}u;\n" for n in gl if init[n])
        setup += "".join(f"        sbuf[({k} * 256 + lslot) * 4] = {init[n]}u;\n" for k, n in enumerate(sh))
        setup += "".join(f'        asm volatile("mbarrier.init.shared::cta.b64 [%0], {init[n]};" :: "r"(to_shared(&mbar[{k} * 256 + lslot])) : "memory");\n'
                         for k, n in enumerate(mb))
        # the initial values are generic writes; asynchronous copies read through the async proxy
        setup += '        asm volatile("fence.proxy.async;" ::: "memory");\n    }\n    __syncthreads();\n'
    exit_bar = ""
    if dsmem:
        # each location is initialized in its own CTA by the first role of that CTA; a cluster barrier makes the
        # values visible to the other CTAs; a second one at the end keeps every CTA (and its shared memory) alive
        # until the other CTAs are done with it
        first = {g: groups.index(g) for g in set(groups)}
        setup = "    if (a != NONE) {\n"
        setup += "".join(f"        if (role == {first[owner[n]]}) sbuf[({k} * 256 + lslot) * 4] = {init[n]}u;\n"
                         for k, n in enumerate(sh))
        setup += "".join(f'        if (role == {first[owner[n]]}) asm volatile("mbarrier.init.shared::cta.b64 [%0], {init[n]};" '
                         f':: "r"(to_shared(&mbar[{k} * 256 + lslot])) : "memory");\n' for k, n in enumerate(mb))
        setup += ('        asm volatile("fence.mbarrier_init.release.cluster;\\n\\tfence.proxy.async;" ::: "memory");\n'
                  '    }\n    asm volatile("barrier.cluster.arrive;\\n\\tbarrier.cluster.wait;" ::: "memory");\n')
        exit_bar = '    asm volatile("barrier.cluster.arrive;\\n\\tbarrier.cluster.wait;" ::: "memory");\n'
    src = (f"// Generated by tools/litmus/to_cuda.py from tests/litmus/{tid}.litmus. Do not edit.\n"
           + "".join(f"// {ln}\n" for ln in t.format().splitlines()) + KERNEL_HEAD
           + f"struct L {{\n{fields}}};\n\n" + "\n".join(bodies)
           + KERNEL_MAIN87.format(ngloc=max(len(gl), 1), nregs=max(len(regs), 1), nroles=len(t.threads), setup=setup,
                                  cluster_bar=('        asm volatile("barrier.cluster.arrive;\\n\\tbarrier.cluster.wait;" ::: "memory");\n'
                                               if cluster_bar else ""),
                                  loc_init=loc_init, exit_none=("    " + exit_bar) if exit_bar else "",
                                  exit_role=exit_bar,
                                  switch="".join(f"    case {k}: role{k}(l, out); break;\n" for k in range(len(t.threads)))))
    spec = "\n".join([f"# Generated by tools/litmus/to_cuda.py from tests/litmus/{tid}.litmus", "kernel litmus",
                      f"roles {len(t.threads)}", f"placement {place}", f"nregs {len(regs)}", f"ngloc {len(gl)}",
                      f"cluster_barrier {int(cluster_bar)}",
                      *(["warp_barrier 1"] if warp_bar and not cluster_bar else []),
                      *(["dsmem 1"] if dsmem else []),
                      *[f"group {k} {g}" for k, g in enumerate(groups) if place == "mixed"],
                      *[f"init {gl.index(n)} {init[n]}" for n in gl if init[n] and place != "same-cta"],
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
{exit_none}        return;
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
{exit_role}}}
"""


def tests() -> list[Path]:
    return sorted((SUITE / "ptx").rglob("*.litmus"))


def test_id(p: Path) -> str:
    return p.relative_to(SUITE).with_suffix("").as_posix()


def out_dir(tid: str) -> Path:
    return OUT / tid.removeprefix("ptx/")


def generate_all() -> tuple[dict[Path, str], dict[str, str]]:
    files, skipped = {}, {}
    for p in tests():
        tid = test_id(p)
        try:
            gen = generate87 if tid.startswith(("ptx/kamui/ptx87/", "ptx/imported/")) else generate
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

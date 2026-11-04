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
import struct
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
    if (d)  /* a start delay; an empty loop would not do, ptxas removes it */
        asm volatile("nanosleep.u32 %0;" :: "r"(d) : "memory");
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


def _mask_lines(mask: str) -> list[str]:
    """The ctaMask register `cm` of a multicast copy: a constant, or "rank" for the bit of the issuing CTA."""
    if mask != "rank":
        return [".reg .b16 cm;", f"mov.b16 cm, {mask};"]
    return [".reg .b16 cm;", ".reg .u32 cr, c1;", "mov.u32 cr, %%cluster_ctarank;", "mov.u32 c1, 1;",
            "shl.b32 cr, c1, cr;", "cvt.u16.u32 cm, cr;"]
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


def _operands(i: litmus.Instr) -> list[str]:
    """The operands of an instruction, with the destinations of a multicast copy (`d0+d1`) split."""
    return [x for a in i.args for x in a.split("+")]


def _locs87(t: litmus.Litmus):
    """name -> (kind, init): kind global, shared or mbar; init the initial value (mbar: the arrival count)."""
    init, owner, aliases, generic = {}, {}, set(), {}
    for d in t.init:
        lhs, rhs = (x.strip() for x in d.split("=", 1)) if "=" in d else (d, "")
        if ":" in lhs:
            continue
        m = re.fullmatch(r"(\w+)\s*@\s*(\w+)\s+aliases\s+(\w+)", d.strip())
        if m:
            # a generic alias is another virtual address of the same memory (the runner maps the memory twice); a
            # proxy alias (surface, texture, constant) is harmless if the test never uses it
            if m.group(2) == "generic":
                generic[m.group(1)] = m.group(3)
            else:
                aliases.add(m.group(1))
            continue
        m = re.fullmatch(r"(.*?)\s*@\s*cta\s+(\d+)", rhs)
        if m:
            rhs, owner[lhs] = m.group(1).strip(), int(m.group(2))
        m = re.fullmatch(r"mbarrier\((\d*)\)", rhs)
        g = re.fullmatch(r"(\w+)\[([01])\]", lhs)
        if m:
            # no count: the test initializes the mbarrier itself (the slot starts as zero)
            init[lhs] = ("mbar", int(m.group(1)) if m.group(1) else None)
        elif g and re.fullmatch(r"\d+", rhs):
            # a 16-bit granule of a 32-bit location (D6): x[0] is the low half, x[1] the high half
            old = init.get(g.group(1), (None, 0))[1]
            init[g.group(1)] = (None, old | (int(rhs) & 0xffff) << (16 * int(g.group(2))))
        elif re.fullmatch(r"-?\d+", rhs) and re.fullmatch(r"\w+", lhs):
            init[lhs] = (None, int(rhs))
        else:
            raise Unsupported(f"initial state {d!r}")
    kinds = {}
    for _, i in t.instrs():
        q = i.quals
        names = [re.sub(r"\[[01]\]$", "", a) for a in _operands(i)
                 if re.fullmatch(r"[A-Za-z_]\w*(\[[01]\])?", a) and not re.fullmatch(r"r\d+|_", a)]
        if i.op == "bar" or (i.op == "barrier" and i.quals[:1] != ["cluster"]):
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
                pos = next(k for k, x in enumerate(i.args) if n in x.split("+"))
                shared = pos < len(spaces) and spaces[pos] != "global"
                if "tensor" in q and pos >= 1:  # the tensor map and the source of a tensor load are global
                    shared = pos == 0 and spaces[0] != "global" or (pos == 1 and spaces[0] == "global")
            elif i.op == "wgmma" or i.op in ("ldmatrix", "stmatrix"):
                shared = True
            elif i.op == "tensormap":
                shared = n != i.args[0] if "cp_fenceproxy" in q else False
            else:
                shared = "shared" in q or "shared::cta" in q or "shared::cluster" in q
            kinds[n] = "shared" if shared or kinds.get(n) == "shared" else kinds.get(n, "global")
    _locs87.owner = owner
    _locs87.generic = generic
    for y, x in generic.items():
        kinds[y] = "alias"
    _locs87.granular = {re.sub(r"\[[01]\]$", "", d.split("=")[0].strip()) for d in t.init
                        if re.fullmatch(r"\s*\w+\[[01]\]\s*=.*", d)}
    return kinds, {n: v for n, (_, v) in init.items()}


def _emit87(i: litmus.Instr, ops: dict[str, str], kinds, tx: int = TX_BYTES) -> list[str]:
    q, a = i.quals, i.args
    if i.op == "wgmma":
        if q[:1] in (["fence"], ["commit_group"]) or q[:1] == ["wait_group"]:
            return [f"{i.text};"]
        if q[:1] == ["mma_async"] and len(a) == 3:
            # m64n8k16 with A (2048 bytes) and B (512 bytes) in shared memory; B is zero except its first element, 1.0,
            # so the first accumulator of thread 0 is A's first element: the f16 value whose bits are the location's
            # value (a subnormal, exact); the role converts it back after the last wait (_wgmma_tail)
            r, aa, cc = a
            k = ops[r + "#wg"]
            return ["{", ".reg .b64 da, db;", ".reg .pred pz;",
                    f"cvt.u64.u32 da, {ops[aa]};", "shr.b64 da, da, 4;", "and.b64 da, da, 16383;",
                    "or.b64 da, da, 0x0000001000080000;",
                    f"cvt.u64.u32 db, {ops[cc]};", "shr.b64 db, db, 4;", "and.b64 db, db, 16383;",
                    "or.b64 db, db, 0x0000001000080000;", "setp.ne.b32 pz, 0, 0;",
                    f"wgmma.mma_async.sync.aligned.m64n8k16.f32.f16.f16 {{wd{k}0, wd{k}1, wd{k}2, wd{k}3}}, da, db, pz, "
                    "1, 1, 0, 0;", "}"]
    if i.op == "stmatrix" and len(a) == 2 and re.fullmatch(r"-?\d+", a[1]):
        # every lane gives the row address (8 identical rows); the lanes holding element 0 of a row give the value,
        # the others 0, so the location's word gets the value and the rest of its 16-byte slot 0
        return ["{", ".reg .b32 sv, ln;", ".reg .pred ps;", "mov.u32 ln, %%laneid;", "and.b32 ln, ln, 3;",
                "setp.eq.u32 ps, ln, 0;", f"selp.b32 sv, {a[1]}, 0, ps;",
                f"stmatrix.sync.aligned.m8n8.x1.shared.b16 [{ops[a[0]]}], {{sv}};", "}"]
    if i.op == "ldmatrix" and len(a) == 2:
        # lane 0 gets row 0, elements 0 and 1: the location's 32-bit word
        return [f"ldmatrix.sync.aligned.m8n8.x1.shared.b16 {{{ops[a[0]]}}}, [{ops[a[1]]}];"]
    if i.op == "tensormap" and q[:1] == ["replace"] and "global_address" in q and len(a) == 2:
        # the map's global address becomes the buffer of map value v (the litmus value of tm)
        return [f"tensormap.replace.tile.global_address.global.b1024.b64 [{ops[a[0]]}], {ops[a[0] + '#b' + a[1]]};"]
    if i.op == "cp" and "tensor" in q and "im2col" not in q and "prefetch" not in q:
        mc = "multicast::cluster" in q
        if q[:2] == ["async", "bulk"] and q[3:5] == ["1d", "shared::cluster"]:
            d, g, b, tm, _ = a
            dst, mb = (ops[d.split("+")[0]], ops[b.split("+")[0]]) if mc else \
                (ops.get(d + "#cl", ops[d]), ops.get(b + "#cl", ops[b]))
            ins = (f"cp.async.bulk.tensor.1d.shared::cluster.global.tile.mbarrier::complete_tx::bytes"
                   f"{'.multicast::cluster' if mc else ''} [{dst}], [{ops[tm]}, {{0}}], [{mb}]{', cm' if mc else ''};")
            return ["{", *_mask_lines(ops["#mask"]), ins, "}"] if mc else [ins]
        if q[:2] == ["async", "bulk"] and q[3:5] == ["1d", "global"]:
            g, s_, tm, _ = a
            return [f"cp.async.bulk.tensor.1d.global.shared::cta.tile.bulk_group [{ops[tm]}, {{0}}], [{ops[s_]}];"]
        if q[:3] == ["reduce", "async", "bulk"] and "add" in q:
            g, s_, tm, _ = a
            return [f"cp.reduce.async.bulk.tensor.1d.global.shared::cta.add.tile.bulk_group [{ops[tm]}, {{0}}], "
                    f"[{ops[s_]}];"]
    if i.op == "cp" and "multicast::cluster" in q and "tensor" not in q and q[:2] == ["async", "bulk"]:
        d, g, b = a
        return ["{", *_mask_lines(ops["#mask"]),
                f"cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes.multicast::cluster "
                f"[{ops[d.split('+')[0]]}], [{ops[g]}], {TX_BYTES}, [{ops[b.split('+')[0]]}], cm;", "}"]
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
    if i.op == "cp" and q[:3] == ["async", "bulk", "prefetch"] and "tensor" not in q and len(a) == 1 \
            and kinds.get(a[0]) == "global":
        return ["{", ".reg .b64 al;", f"and.b64 al, {ops[a[0]]}, -16;",
                f"cp.async.bulk.prefetch{''.join('.' + x for x in q[3:])} [al], 16;", "}"]
    if i.op == "ld" and "nc" in q:
        return [f"ld.global.nc.u32 {ops[a[0]]}, [{ops[a[1]]}];"]
    if i.op == "ld" and not q and len(a) == 2 and re.fullmatch(r"-?\d+", a[1]):
        return [f"mov.u32 {ops[a[0]]}, {a[1]};"]  # a register move in the litmus dialect: ld r0, 1
    if i.op == "ldu":
        return [f"ldu.global.u32 {ops[a[0]]}, [{ops[a[1]]}];"]
    gm = re.fullmatch(r"(\w+)\[([01])\]", a[1]) if i.op == "ld" and len(a) == 2 else None
    if gm and gm.group(1) in ops:
        # a 16-bit granule of a 32-bit location: x[1] is the high half, at byte offset 2 (D6)
        n, off = gm.group(1), 2 * int(gm.group(2))
        return wrap([f"ld{_sem87(i, 'weak')}.{sp(n)}{cop}.u16 {ops[a[0]]}, [{ad(n)}+{off}]{tail};"])
    if i.op == "ld" and len(a) == 2 and a[1] in ops and not any(re.fullmatch(r"v\d", x) for x in q):
        ty = "u16" if "b16" in q else "u32"
        return wrap([f"ld{_sem87(i, 'weak')}.{sp(a[1])}{cop}.{ty} {ops[a[0]]}, [{ad(a[1])}]{tail};"])
    gs = re.fullmatch(r"(\w+)\[([01])\]", a[0]) if i.op == "st" and len(a) == 2 and "async" not in q else None
    if gs and gs.group(1) in ops and re.fullmatch(r"\d+", a[1]):
        # a 16-bit store to one granule of a 32-bit location (D6)
        n, off = gs.group(1), 2 * int(gs.group(2))
        return wrap([f"mov.u32 t, {a[1]};", f"st{_sem87(i, 'weak')}.{sp(n)}{cop}.u16 [{ad(n)}+{off}], t{tail};"])
    if i.op == "st" and len(a) == 2 and "async" not in q and not any(re.fullmatch(r"v\d", x) for x in q):
        gv = re.fullmatch(r"(\d+):(\d+)", a[1])  # x, 1:2 writes 1 to the low granule and 2 to the high one
        val = str(int(gv.group(1)) | int(gv.group(2)) << 16) if gv else \
            a[1] if re.fullmatch(r"-?\d+", a[1]) else ops.get(a[1])
        if not gv and a[0] + "#g" in ops and re.fullmatch(r"\d+", a[1]):
            # one value for a location with two granules writes it to both (the dialect of tests/litmus/README.md)
            val = str(int(a[1]) | int(a[1]) << 16)
        if val is None:
            raise Unsupported(f"store of a register {i.text!r}")
        return wrap([f"mov.u32 t, {val};", f"st{_sem87(i, 'weak')}.{sp(a[0])}{cop}.u32 [{ad(a[0])}], t{tail};"])
    if i.op == "st" and "v2" in q and len(a) == 4 and "async" not in q:
        # st.v2 x, y, 1, 2: one 64-bit store; y is the word after x (the generator places it there)
        return ["{", ".reg .u32 v0, v1;", f"mov.u32 v0, {a[2]};", f"mov.u32 v1, {a[3]};",
                f"st{_sem87(i, 'weak')}.{sp(a[0])}.v2.u32 [{ad(a[0])}], {{v0, v1}};", "}"]
    if i.op == "atom" and "b128" in q and "cas" in q and len(a) == 4:
        d, loc, cmp_, new = a
        return ["{", ".reg .b128 qc, qn, qd;", ".reg .b64 lo, hi;", "mov.b64 hi, 0;",
                f"mov.b64 lo, {cmp_};", "mov.b128 qc, {lo, hi};", f"mov.b64 lo, {new};", "mov.b128 qn, {lo, hi};",
                f"atom{_sem87(i, 'relaxed')}.{sp(loc)}.cas.b128 qd, [{ad(loc)}], qc, qn;", "mov.b128 {lo, hi}, qd;",
                f"cvt.u32.u64 {ops[d]}, lo;", "}"]
    if i.op == "membar" or i.op == "griddepcontrol":
        return [f"{i.text};"]
    if i.op == "cp" and q[:3] == ["async", "bulk", "prefetch"] and "tensor" in q:
        return ["{", ".reg .b32 c0;", "mov.b32 c0, 0;",
                f"cp.async.bulk.prefetch.tensor.1d.L2.global.tile [{ops[a[0]]}, {{c0}}];", "}"]
    if i.op == "createpolicy" and len(a) == 2:
        # a policy is a 64-bit value; the litmus register only names it
        return ["{", ".reg .b64 polx;", f"{i.text.split()[0]} polx, {a[1]};", "}"]
    if i.op in ("atom", "red") and "f16" in q and "add" in q and "async" not in q:
        # half precision: the litmus value v is the half-precision number v (exact for small integers)
        args = list(a)
        dst = None if i.op == "red" else ops[args.pop(0)]
        loc, v = args
        bits = struct.unpack("<H", struct.pack("<e", float(int(v))))[0]
        head = f"{i.op}{_sem87(i, 'relaxed')}.{sp(loc)}.add.noftz.f16"
        return ["{", ".reg .f16 hv, ho;", ".reg .f32 hf;", f"mov.b16 hv, 0x{bits:04x};",
                f"{head} {'ho, ' if dst else ''}[{ad(loc)}], hv;"] + \
            ([ "cvt.f32.f16 hf, ho;", f"cvt.rzi.u32.f32 {dst}, hf;"] if dst else []) + ["}"]
    if i.op in ("atom", "red") and "v2" in q and "f32" in q and "add" in q and "async" not in q:
        # atom.v2.f32.add r0, r1, x, y, a, b: one vector operation on x and the word after it (y); the litmus value
        # v is the single-precision number v
        args = list(a)
        dsts = [] if i.op == "red" else [ops[args.pop(0)], ops[args.pop(0)]]
        x, _, v0, v1 = args
        f = lambda v: f"0f{struct.unpack('<I', struct.pack('<f', float(int(v))))[0]:08X}"  # noqa: E731
        head = f"{i.op}{_sem87(i, 'relaxed')}.{sp(x)}.v2.f32.add"
        out = ["{", ".reg .f32 f0, f1, o0, o1;", f"mov.f32 f0, {f(v0)};", f"mov.f32 f1, {f(v1)};"]
        if dsts:
            out += [f"{head} {{o0, o1}}, [{ad(x)}], {{f0, f1}};", f"cvt.rzi.u32.f32 {dsts[0]}, o0;",
                    f"cvt.rzi.u32.f32 {dsts[1]}, o1;"]
        else:
            out += [f"{head} [{ad(x)}], {{f0, f1}};"]
        return out + ["}"]
    if i.op == "discard" and len(a) == 2 and kinds.get(a[0]) == "global":
        return [f"discard.global.L2 [{ops[a[0]]}], {a[1]};"]
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
    if i.op == "fence" and "tensormap::generic" in q:
        # the acquire side names the tensor map (a generic address of global memory) and its size, 128
        scope = i.scope or "gpu"
        if "acquire" in q and a:
            return [f"fence.proxy.tensormap::generic.acquire.{scope} [{ops[a[0]]}], 128;"]
        return [f"fence.proxy.tensormap::generic.release.{scope};"]
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
        if kind == "init" and len(a) == 2:
            return [f"mbarrier.init.shared::cta.b64 [{ops[a[0]]}], {a[1]};"]
        if kind == "inval" and len(a) == 1:
            return [f"mbarrier.inval.shared::cta.b64 [{ops[a[0]]}];"]
        if kind in ("arrive", "arrive_drop") and re.fullmatch(r"r\d+", a[0]) and len(a) == 2 and q[1:2] != ["expect_tx"]:
            # the arrive returns the phase state (64 bits) in a register: s<r>; the litmus register gets its low half
            if remote:
                raise Unsupported(f"a remote arrive returns no state on the GPU {i.text!r}")
            r, b = a
            return [f"mbarrier.{kind}.{sem or 'release'}.{scope}.shared::cta.b64 s{r}, [{ops[b]}];",
                    f"cvt.u32.u64 {ops[r]}, s{r};"]
        if kind in ("test_wait", "try_wait") and "parity" not in q and len(a) == 3 and re.fullmatch(r"r\d+", a[2]) \
                and not remote:
            r, b, tok = a
            return [f"mbarrier.{kind}.{sem or 'acquire'}.{scope}.shared::cta.b64 p, [{ops[b]}], s{tok};",
                    f"selp.u32 {ops[r]}, 1, 0, p;"]
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
        if q[0] == "async" and rest == ["bulk", "shared::cluster", "shared::cta", "mbarrier::complete_tx::bytes"]:
            # a bulk copy from the own CTA's shared memory into (another CTA's) shared memory of the cluster
            cl = lambda n: ops.get(n + "#cl", ops[n])  # noqa: E731
            return [f"cp.async.bulk.shared::cluster.shared::cta.mbarrier::complete_tx::bytes [{cl(a[0])}], "
                    f"[{ops[a[1]]}], {TX_BYTES}, [{cl(a[2])}];"]
        if q[0] == "async" and rest == ["bulk", "shared::cluster", "global", "mbarrier::complete_tx::bytes"]:
            cl = lambda n: ops.get(n + "#cl", ops[n])  # noqa: E731
            return [f"cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes [{cl(a[0])}], [{ops[a[1]]}], "
                    f"{TX_BYTES}, [{cl(a[2])}];"]
        if q[:2] == ["reduce", "async"] and q[2:] == ["bulk", "global", "shared::cta", "bulk_group", "add", "u32"]:
            return [f"cp.reduce.async.bulk.global.shared::cta.bulk_group.add.u32 [{ops[a[0]]}], [{ops[a[1]]}], "
                    f"{TX_BYTES};"]
    raise Unsupported(f"instruction {i.text!r}")


def _barriers(t: litmus.Litmus, groups: list[int], rinit, widths=None) -> tuple[dict[int, list[str]], int]:
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
            if i.op not in ("bar", "barrier") or (i.op == "barrier" and i.quals[:1] == ["cluster"]):
                continue
            q, a = i.quals, i.args
            if i.op == "barrier":  # barrier{.cta}.sync|arrive{.aligned} a{, b}: the same barriers as bar.sync|arrive
                q = [x for x in q if x not in ("cta", "aligned")]
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
            key = (key, groups[th.tid])  # CTA barriers belong to one CTA: the same id in two CTAs is two barriers
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
    # hardware barriers are numbered within each CTA (key[1] is the CTA group)
    order = {g: sorted((k for k in keys if k[1] == g), key=str) for g in {k[1] for k in keys}}
    for i, tid_, key, mode, want in uses:
        parts = keys[key]
        if want is not None and (want != len(parts) or len({groups[k] for k in parts}) != 1):
            raise Unsupported(f"a barrier that cannot complete as the test intends on the GPU {i.text!r}")
        n = sum(widths[k] if widths else 1 for k in parts if groups[k] == groups[tid_])  # warps that take part
        code[id(i)] = [f"add.u32 bid, %gb, {order[key[1]].index(key)};",
                       f"barrier.{'arrive' if mode == 'arrive' else 'sync'} bid, {32 * n};"]
    return code, max((len(v) for v in order.values()), default=0)


WIDE_OPS = ("wgmma", "ldmatrix", "stmatrix", "tensormap", "fence", "membar", "bar", "barrier", "griddepcontrol")


def _widths(t: litmus.Litmus) -> list[int] | None:
    """Uniform roles: a thread with wgmma takes a warpgroup (4 warps), one with a warp-wide instruction (ldmatrix,
    stmatrix, tensormap.*), a tensor copy or a tensor-map prefetch a warp; then every role is whole warps (a role
    without such instructions: one warp). A tensor copy or prefetch issued by a diverged warp (lanes of several
    instances, or with different start delays) hung on the H100 (cp.async.bulk.prefetch.tensor and prefetch.tensormap
    in the shuffle and spread configurations), so it is issued by one lane of a warp that runs one instance.
    None: lanes are instances, as in every other test."""
    w = []
    for th in t.threads:
        ops = [i.op for i in th.instrs if not i.is_empty]
        tensor = any(i.op == "cp" and "tensor" in i.quals or i.op == "prefetch" and "tensormap" in i.quals
                     for i in th.instrs)
        w.append(4 if "wgmma" in ops else 1 if {"ldmatrix", "stmatrix", "tensormap"} & set(ops) or tensor else 0)
    return [max(1, x) for x in w] if any(w) else None


def _uniform_instances(widths: list[int], place: str, groups: list[int]) -> int:
    """Instances per CTA (or cluster) of uniform roles: the runner's uniform_layout."""
    span, wg = {}, {}
    for k, w in enumerate(widths):
        g = 0 if place == "same-cta" else groups[k]
        span[g] = span.get(g, 0) + w
        wg[g] = wg.get(g, 0) + (w == 4)
    ni = ROLE_THREADS // 32
    for g in span:
        m = 0 if span[g] > ROLE_THREADS // 32 or wg[g] > 1 else 1 if wg[g] else (ROLE_THREADS // 32) // span[g]
        ni = min(ni, m)
    return ni


def generate87(t: litmus.Litmus, tid: str) -> tuple[str, str]:
    if len(t.threads) > MAX_ROLES:
        raise Unsupported("more than four threads")
    if t.has_loops:
        raise Unsupported("loops or grids")
    grids = [th.grid or 0 for th in t.threads]
    multigrid = len(set(grids)) > 1
    place = placement(t, mixed=True)
    groups = cta_groups(t)
    rinit = reg_init(t)
    kinds, init = _locs87(t)
    widths = _widths(t)
    barcode, nbar = _barriers(t, groups, rinit, widths)
    ni = _uniform_instances(widths, place, groups) if widths else None
    if widths and not ni:
        raise Unsupported("the warps of the uniform roles do not fit in a CTA")
    if nbar:
        per_cta = max(groups.count(g) for g in set(groups))
        ninst = ni if widths else (ROLE_THREADS // 32) // per_cta if place in ("same-cta", "mixed") else 1
        if 1 + ninst * nbar > (15 if widths and 4 in widths else 16):
            raise Unsupported("more than 15 hardware barriers per CTA")
    # generic aliases: another virtual address of a global location (the runner maps the memory twice)
    aliases = {y: x for y, x in _locs87.generic.items() if y in kinds}
    for y, x in aliases.items():
        kinds.setdefault(x, "global")
        init.setdefault(x, 0)
        kinds[y] = "global"
    # wgmma operands: A (the location read) and B, in tiles of their own
    wga, wgb = {}, {}
    for _, i in t.instrs():
        if i.op == "wgmma" and i.quals[:1] == ["mma_async"]:
            wga[i.args[1]], wgb[i.args[2]] = True, True
    # tensor maps: the global location of the map, the location it points to (map value 0), and one buffer for each
    # value a tensormap.replace gives it (word 0: the source's initial value, word 1: the map value, word 2: 1, a
    # marker that the copy arrived)
    tmaps: dict[str, list] = {}
    for _, i in t.instrs():
        q = i.quals
        if i.op == "cp" and "tensor" in q:
            if "im2col" in q:
                raise Unsupported("im2col tensor copies (need a 3-dimensional tensor map)")
            if "prefetch" in q:
                tmaps.setdefault(i.args[0], [None, {0}])
            elif q[:2] == ["async", "bulk"] and q[3:5] == ["1d", "shared::cluster"]:
                tmaps.setdefault(i.args[3], [None, {0}])[0] = i.args[1]
            else:
                tmaps.setdefault(i.args[2], [None, {0}])[0] = i.args[0]
        elif i.op == "tensormap":
            if "cp_fenceproxy" in q:
                raise Unsupported("tensormap.cp_fenceproxy (needs a tensor map in shared memory)")
            if "replace" in q and "global_address" in q:
                tmaps.setdefault(i.args[0], [None, {0}])[1].add(int(i.args[1]))
        elif i.op == "prefetch" and "tensormap" in q:
            tmaps.setdefault(i.args[0], [None, {0}])
    extra_init: list[tuple[str, int, int]] = []  # (location, value, word)
    for tm, (src, vers) in tmaps.items():
        if src is None:
            src = f"{tm}__b0"
            kinds[src], init[src] = "global", 0
            tmaps[tm][0] = src
        extra_init.append((src, 1, 2))
        for v in sorted(vers - {0}):
            n = f"{tm}__b{v}"
            kinds[n], init[n] = "global", init.get(src, 0)
            extra_init += [(n, v, 1), (n, 1, 2)]
    gl = [n for n in kinds if kinds[n] == "global" and n not in aliases]
    sh = [n for n in kinds if kinds[n] == "shared" and n not in wga and n not in wgb]
    mb = [n for n in kinds if kinds[n] == "mbar"]
    if multigrid and (sh or mb or nbar or widths or any(i.op == "barrier" for _, i in t.instrs())):
        raise Unsupported("grids with shared memory or barriers")
    # multicast: the destinations (and their mbarriers) in several CTAs sit at the same offset in each CTA
    mcast = [g for _, i in t.instrs() if i.op == "cp" and "multicast::cluster" in i.quals
             for g in (i.args[0].split("+"), i.args[2].split("+"))]

    def index(names):
        idx, k = {}, 0
        for n in names:
            if n in idx:
                continue
            for m in next((g for g in mcast if n in g), [n]):
                idx[m] = k
            k += 1
        return idx, k
    sidx, nsh = index(sh)
    midx, nmb = index(mb)
    # Distributed shared memory: a shared location or mbarrier lives in one CTA of the cluster (`@cta N`, else the
    # CTA of the first thread that names it); that CTA initializes it, other CTAs reach it through its
    # shared::cluster address (mapa). The CTA of test group g is CTA rank g of the cluster (spec `dsmem 1`).
    dsmem = bool(sh or mb) and place != "same-cta"
    # shared slots: 16 bytes each, one per instance slot `lslot` of the CTA. A tensor copy needs a 128-byte aligned
    # shared address, so with one the slots are 128 bytes, and only as many as lslot can reach in this placement
    tensor_sh = any(i.op == "cp" and "tensor" in i.quals and "prefetch" not in i.quals for _, i in t.instrs())
    sw = 32 if tensor_sh else 4
    if not tensor_sh:
        ns = 256
    elif widths:
        ns = 8  # one slot per instance of the CTA's warps (at most 6)
    elif place == "same-cta":
        ns = 6 // len(t.threads) * 32
    elif place == "mixed":
        ns = 6 // max(groups.count(g) for g in set(groups)) * 32
    else:
        ns = 192 if dsmem else 256
    if nsh * ns * sw * 4 + 2 * 256 * 8 > 48 * 1024:
        raise Unsupported("tensor copies with more shared memory than a CTA's static limit")
    owner: dict[str, int] = {}
    if sh or mb:
        if place == "diff-cluster":
            raise Unsupported("shared memory across clusters")
        cta_group = {th.cta: groups[th.tid] for th in t.threads}
        for n in sh + mb:
            o = _locs87.owner.get(n)
            if o is not None and o not in cta_group:
                raise Unsupported(f"{n} lives in a CTA that runs no thread")
            owner[n] = cta_group[o] if o is not None else \
                next(groups[th.tid] for th in t.threads if any(n in _operands(i) for i in th.instrs))
        for th in t.threads:
            for i in th.instrs:
                for n in set(_operands(i)) & set(owner):
                    if groups[th.tid] != owner[n] and "shared::cluster" not in i.quals:
                        raise Unsupported(f"{n} used from another CTA outside the cluster window {i.text!r}")
    if (wga or wgb) and place != "same-cta":
        raise Unsupported("wgmma operands in another CTA")
    asyncst = any(i.op in ("st", "red") and i.quals[:1] == ["async"] for _, i in t.instrs())
    bulk = any(i.op == "cp" and "bulk" in i.quals for _, i in t.instrs())
    if asyncst and bulk:
        raise Unsupported("st.async or red.async together with bulk copies (two transaction sizes)")
    tx = 4 if asyncst else TX_BYTES
    if nsh > 4 or nmb > 2:
        raise Unsupported("too many shared locations")
    regs: list[tuple[int, str]] = []
    for th in t.threads:
        for i in th.instrs:
            if i.is_empty:
                continue
            writes = i.op in ("ld", "ldu", "atom", "ldmatrix") or (i.op == "mbarrier" and i.quals[0] in
                                                                     ("test_wait", "try_wait", "arrive", "arrive_drop")) \
                or (i.op == "wgmma" and i.quals[:1] == ["mma_async"])
            # a register written more than once keeps its last value, as in the litmus test
            dsts = i.args[:2] if i.op == "atom" and "v2" in i.quals else i.args[:1]
            if i.op == "cp" and "tensor" in i.quals and i.quals[3:5] == ["1d", "shared::cluster"]:
                writes, dsts = True, i.args[-1:]  # the map value the tensor copy used
            for r in dsts if writes else []:
                if re.fullmatch(r"r\d+", r) and (th.tid, r) not in regs:
                    regs.append((th.tid, r))
    split: set = set()
    finals: list[str] = []
    # st.v2 x, y: y is the word after x, not a location of its own
    tied = {i.args[1]: i.args[0] for _, i in t.instrs() if i.op == "st" and "v2" in i.quals and len(i.args) == 4}
    tied.update({i.args[-3]: i.args[-4] for _, i in t.instrs()
                 if i.op in ("atom", "red") and "v2" in i.quals and len(i.args) >= 4})
    gl = [n for n in gl if n not in tied]
    for c in litmus.cond_atoms(t.condition):
        for side in (c.lhs, c.rhs):
            side = re.sub(r"^(\d+):", r"P\1:", side)
            if side in tied:
                raise Unsupported(f"condition on {side}, the second word of a vector store")
            if side in aliases:
                raise Unsupported(f"condition on {side}, an alias")
            if re.fullmatch(r"-?\d+", side):
                continue
            if ":" in side:
                k, r = side[1:].split(":")
                part = re.fullmatch(r"(r\d+)\[([01])\]", r)
                if part:  # a 16-bit half of a 32-bit register (D6)
                    r = part.group(1)
                    split.add((int(k), r))
                if (int(k), r) not in regs:
                    raise Unsupported(f"condition on {side}, which no load writes")
                if any(i.op == "mbarrier" and i.quals[:1] in (["arrive"], ["arrive_drop"]) and i.args[:1] == [r]
                       for i in t.threads[int(k)].instrs):
                    # the GPU returns the mbarrier state as an opaque 64-bit value, not the model's phase state
                    raise Unsupported(f"condition on {side}, the state an mbarrier arrive returns")
            elif side in sh and (place == "same-cta" or dsmem):
                if side not in finals:  # the final value of a shared location: read once every role is done
                    finals.append(side)
            elif side not in gl:
                raise Unsupported(f"condition on {side}")
    # the output slots: a register whose halves the condition names (P1:r0[0]) takes two slots
    slots = [(k, f"{r}[{h}]") for k, r in regs for h in ((0, 1) if (k, r) in split else (None,))]
    slots = [(k, n.replace("[None]", "")) for k, n in slots]
    slots += [(-1, n) for n in finals]  # thread -1: a location
    cluster_bar = any(i.op == "barrier" and i.quals[:1] == ["cluster"] for _, i in t.instrs())
    warp_bar = cluster_bar or bool(nbar) or dsmem
    tensor_dsts = {i.args[0] for _, i in t.instrs() if i.op == "cp" and "tensor" in i.quals
                   and i.quals[3:5] == ["1d", "shared::cluster"] and "multicast::cluster" not in i.quals}
    bodies = []
    for th in t.threads:
        W = widths[th.tid] if widths else 0
        mine = [r for k, r in regs if k == th.tid]
        used = [n for n in kinds if any(n in [re.sub(r"\[[01]\]$", "", x) for x in _operands(i)] for i in th.instrs)]
        used += [f"{i.args[0]}__b{i.args[1]}" for i in th.instrs if i.op == "tensormap" and "replace" in i.quals
                 and f"{i.args[0]}__b{i.args[1]}" not in used]
        uses_bar = any(id(i) in barcode for i in th.instrs)
        ops = {r: f"%{n}" for n, r in enumerate(mine)}
        ops.update({n: f"%{len(mine) + k}" for k, n in enumerate(used)})
        ops.update({n + "#g": "" for n in used if n in _locs87.granular})
        ops.update({n.replace("__b", "#b"): ops[n] for n in used if "__b" in n})
        # shared locations through the cluster window: their shared::cluster addresses (in the owner CTA)
        clw = [n for n in used if n in owner and dsmem]
        base = len(mine) + len(used) + (1 if uses_bar else 0)
        ops.update({n + "#cl": f"%{base + k}" for k, n in enumerate(clw)})
        lead_op = f"%{base + len(clw)}"
        # registers no load writes (initial values such as P0:r2=1): asm-local registers
        local = sorted({x for i in th.instrs for x in _operands(i) if re.fullmatch(r"r\d+", x)} - set(mine))
        ops.update({r: f"q{r}" for r in local})
        pre = [f".reg .u32 q{r};" for r in local] + [f"mov.u32 q{r}, {rinit.get((th.tid, r), 0)};" for r in local]
        states = sorted({i.args[0] for i in th.instrs if i.op == "mbarrier" and i.quals[:1] in (["arrive"], ["arrive_drop"])
                         and i.args and re.fullmatch(r"r\d+", i.args[0])})
        pre += [f".reg .b64 s{r};" for r in states]
        mmas = [i for i in th.instrs if i.op == "wgmma" and i.quals[:1] == ["mma_async"]]
        for k, i in enumerate(mmas):
            ops[i.args[0] + "#wg"] = str(k)
            pre.append(f".reg .f32 wd{k}0, wd{k}1, wd{k}2, wd{k}3;")
        for i in th.instrs:
            if i.op == "cp" and "multicast::cluster" in i.quals:
                # with distributed shared memory, test group g is CTA rank g; in one CTA (same-cta), the instance's
                # CTA may have any rank in its cluster, so the mask is computed from %cluster_ctarank
                ops["#mask"] = str(sum(1 << owner[m] for m in i.args[0].split("+"))) if dsmem else "rank"
        gb_op = f"%{len(mine) + len(used)}"
        if uses_bar:
            pre.append(".reg .u32 bid;")
        if W:
            pre += [".reg .pred lp;", f"setp.ne.u32 lp, {lead_op}, 0;"]
        lines, after_leader, nlab = [], False, 0
        for i in th.instrs:
            if i.is_empty:
                continue
            code = [ln.replace("%gb", gb_op) for ln in (barcode.get(id(i)) or _emit87(i, ops, kinds, tx))]
            if not W:
                lines += code
            elif i.op in WIDE_OPS:
                # a warp-wide (or role-wide) instruction: every thread of the role, after the leader's work
                if after_leader:
                    lines.append("bar.warp.sync -1;" if W == 1 else "bar.sync 15, 128;")
                lines += code
                after_leader = False
            else:
                lines += [f"@!lp bra LS{nlab}_%=;"] + code + [f"LS{nlab}_%=:"]
                nlab += 1
                after_leader = True
        # the map value a tensor copy used: once the copy arrived (word 2 of the destination is 1), word 1
        for i in th.instrs:
            if i.op == "cp" and "tensor" in i.quals and i.args[0] in tensor_dsts and i.args[-1] in mine:
                d = i.args[0]
                if owner.get(d, groups[th.tid]) != groups[th.tid]:
                    raise Unsupported("the result of a tensor copy into another CTA")
                wait = [f"WT{nlab}_%=:", f"ld.volatile.shared::cta.u32 t, [{ops[d]}+8];", "setp.ne.u32 p, t, 1;",
                        f"@p bra WT{nlab}_%=;", f"ld.volatile.shared::cta.u32 {ops[i.args[-1]]}, [{ops[d]}+4];"]
                lines += ([f"@!lp bra LS{nlab}_%=;"] + wait + [f"LS{nlab}_%=:"]) if W else wait
                nlab += 1
        if mmas:
            # the accumulator is ready after the last wait; scale the subnormal back to the integer
            lines.append("wgmma.wait_group.sync.aligned 0;")
            for k, i in enumerate(mmas):
                lines += [f"mul.f32 wd{k}0, wd{k}0, 0f4B800000;", f"cvt.rzi.u32.f32 {ops[i.args[0]]}, wd{k}0;"]
        asm = "\n".join(f'        "{ln}\\n\\t"' for ln in [".reg .u32 t;", ".reg .pred p;"] + pre + lines)
        outs = ", ".join(f'"=r"(r_{r})' for r in mine)
        ins = ", ".join([f'"{"l" if kinds[n] == "global" else "r"}"(a_{n})' for n in used]
                        + (['"r"(l.gb)'] if uses_bar else []) + [f'"r"(c_{n})' for n in clw]
                        + (['"r"(lead)'] if W else []))
        mapa = "".join(f"    unsigned c_{n};\n"
                       f'    asm("mapa.shared::cluster.u32 %0, %1, {owner[n] if dsmem else 0};" : "=r"(c_{n}) : "r"(a_{n}));\n'
                       if dsmem else f"    unsigned c_{n} = a_{n};\n" for n in clw)
        store = "".join(f"    out[{slots.index((th.tid, r + '[0]'))}] = r_{r} & 0xffffu;\n"
                        f"    out[{slots.index((th.tid, r + '[1]'))}] = r_{r} >> 16;\n" if (th.tid, r) in split
                        else f"    out[{slots.index((th.tid, r))}] = r_{r};\n" for r in mine)
        if W and store:
            store = "    if (lead) {\n" + store.replace("    out[", "        out[") + "    }\n"
        bodies.append(
            f"// P{th.tid}: {' ; '.join(i.text for i in th.instrs if not i.is_empty)}\n"
            f"__device__ __forceinline__ void role{th.tid}(L &l, unsigned *out) {{\n"
            + "".join(f"    {'unsigned long long' if kinds[n] == 'global' else 'unsigned'} a_{n} = l.{n};\n" for n in used)
            + "".join(f"    unsigned r_{r} = 0;\n" for r in mine) + mapa
            + (f"    unsigned lead = (threadIdx.x % {32 * W}u) == 0;\n" if W else "")
            + f'    asm volatile("{{\\n\\t"\n{asm}\n        "}}"\n        : {outs}\n        : {ins}\n        : "memory");\n'
            + store + "}\n")
    fields = "".join(f"    {'unsigned long long' if kinds[n] == 'global' else 'unsigned'} {n};\n" for n in kinds)
    if nbar:
        fields += "    unsigned gb;\n"
    loc_init = "".join(f"    l.{n} = to_global(mem + lo[{gl.index(n)}]);\n" for n in gl)
    loc_init += "".join(f"    l.{y} = l.{x} + 4;\n" for y, x in tied.items())
    loc_init += "".join(f"    l.{y} = l.{x} + adelta;\n" for y, x in aliases.items())
    loc_init += "".join(f"    l.{n} = to_shared(&sbuf[({sidx[n]} * {ns} + lslot) * {sw}]);\n" for n in sh)
    loc_init += "".join(f"    l.{n} = to_shared(&mbar[{midx[n]} * 256 + lslot]);\n" for n in mb)
    loc_init += "".join(f"    l.{n} = to_shared(&wgA[0]);\n" for n in wga)
    loc_init += "".join(f"    l.{n} = to_shared(&wgB[0]);\n" for n in wgb)
    if nbar:
        # one set of hardware barriers per instance group of a CTA (lslot / 32, or per instance for uniform roles);
        # one role per CTA needs only one
        loc_init += (f"    l.gb = 1 + lslot * {nbar};\n" if widths else
                     f"    l.gb = 1 + (lslot >> 5) * {nbar};\n" if place in ("same-cta", "mixed") else "    l.gb = 1;\n")
    lead_of = (lambda k: f" && (threadIdx.x % {32 * widths[k]}u) == 0") if widths else (lambda k: "")

    def zero(n):  # tensor copies: the destination's other words start at 0 (word 2 marks the arrival)
        return "".join(f"        sbuf[({sidx[n]} * {ns} + lslot) * {sw} + {w}] = 0u;\n" for w in (1, 2, 3)) \
            if n in tensor_dsts or tmaps else ""
    setup = ""
    if place == "same-cta":
        setup = f"    if (a != NONE && role == 0{lead_of(0)}) {{\n        const unsigned *lo = locoff + inst * NGLOC;\n"
        # a tensor map location holds the map the host encodes before the launch; its initial value in the test
        # names the map, not a word to write
        setup += "".join(f"        mem[lo[{gl.index(n)}]] = {init[n]}u;\n" for n in gl if init[n] and n not in tmaps)
        setup += "".join(f"        sbuf[({sidx[n]} * {ns} + lslot) * {sw}] = {init[n]}u;\n" + zero(n) for n in sh)
        setup += "".join(f'        asm volatile("mbarrier.init.shared::cta.b64 [%0], {init[n]};" :: "r"(to_shared(&mbar[{midx[n]} * 256 + lslot])) : "memory");\n'
                         if init[n] is not None else f"        mbar[{midx[n]} * 256 + lslot] = 0ull;\n"
                         for n in mb)
        if wga or wgb:
            # A: zero but its first word (the location); B: zero but its first element, 1.0 in half precision
            setup += ("        for (unsigned w = 0; w < 512; w++) wgA[w] = 0u;\n"
                      + "".join(f"        wgA[0] = {init.get(n, 0)}u;\n" for n in wga)
                      + "        for (unsigned w = 0; w < 128; w++) wgB[w] = 0u;\n        wgB[0] = 0x3c00u;\n")
        # the initial values are generic writes; asynchronous copies read through the async proxy
        setup += '        asm volatile("fence.proxy.async;" ::: "memory");\n    }\n    __syncthreads();\n'
    exit_bar = ""
    if dsmem:
        # each location is initialized in its own CTA by the first role of that CTA; a cluster barrier makes the
        # values visible to the other CTAs; a second one at the end keeps every CTA (and its shared memory) alive
        # until the other CTAs are done with it
        first = {g: groups.index(g) for g in set(groups)}
        setup = "    if (a != NONE) {\n"
        setup += "".join(f"        if (role == {first[owner[n]]}{lead_of(first[owner[n]])}) sbuf[({sidx[n]} * {ns} + lslot) * {sw}] = {init[n]}u;\n"
                         + (f"        if (role == {first[owner[n]]}{lead_of(first[owner[n]])}) {{\n" + zero(n).replace("        sbuf", "            sbuf")
                            + "        }\n" if zero(n) else "") for n in sh)
        setup += "".join(f'        if (role == {first[owner[n]]}{lead_of(first[owner[n]])}) asm volatile("mbarrier.init.shared::cta.b64 [%0], {init[n]};" '
                         f':: "r"(to_shared(&mbar[{midx[n]} * 256 + lslot])) : "memory");\n' if init[n] is not None
                         else f"        if (role == {first[owner[n]]}{lead_of(first[owner[n]])}) mbar[{midx[n]} * 256 + lslot] = 0ull;\n"
                         for n in mb)
        setup += ('        asm volatile("fence.mbarrier_init.release.cluster;\\n\\tfence.proxy.async;" ::: "memory");\n'
                  '    }\n    asm volatile("barrier.cluster.arrive;\\n\\tbarrier.cluster.wait;" ::: "memory");\n')
        exit_bar = '    asm volatile("barrier.cluster.arrive;\\n\\tbarrier.cluster.wait;" ::: "memory");\n'
    final = ""
    if finals and dsmem:
        # after the cluster barrier at the end, the first role of the owner CTA reads the location
        first = {g: groups.index(g) for g in set(groups)}
        final = "".join(f"    if (role == {first[owner[n]]}) out[{slots.index((-1, n))}] = sbuf[({sidx[n]} * {ns} + lslot) * {sw}];\n"
                        for n in finals)
    elif finals:
        # same CTA: the role warps of one instance group meet at a hardware barrier of their own, after the
        # test's barriers (ids 1 + nbar * groups ...), then role 0 reads the location
        ngroups = ni if widths else (ROLE_THREADS // 32) // len(t.threads)
        fb = 1 + ngroups * nbar
        if fb + ngroups > (15 if widths and 4 in widths else 16):
            raise Unsupported("more than 15 hardware barriers per CTA")
        nthreads = f"{32 * sum(widths)}u" if widths else "32u * NROLES"
        final = (f'    asm volatile("bar.sync %0, %1;" :: "r"({fb}u + {"lslot" if widths else "(lslot >> 5)"}), "r"({nthreads}) : "memory");\n'
                 + "".join(f"    if (role == 0) out[{slots.index((-1, n))}] = sbuf[({sidx[n]} * {ns} + lslot) * {sw}];\n"
                           for n in finals))
    # Drain: a CTA must not exit while an asynchronous operation still writes or reads its shared memory (a copy
    # the test does not wait for failed the launch on the H100). After the outputs and final values are read, the
    # owner of each mbarrier waits a bounded time for its first phase, and a thread that issued bulk copies waits
    # for its bulk async-groups; in a cluster, a second barrier keeps every CTA alive until all have drained.
    drain = ""
    if mb and any(i.op in ("cp", "st", "red") and "mbarrier::complete_tx::bytes" in i.quals for _, i in t.instrs()):
        lead0 = {g: groups.index(g) for g in set(groups)}
        for n in mb:
            k = lead0[owner[n]] if dsmem else 0
            drain += (f"    if (role == {k}{lead_of(k)}) {{\n"
                      f"        unsigned ok = 0;\n"
                      f"        for (unsigned w = 0; w < 4096u && !ok; w++)\n"
                      f'            asm volatile("{{\\n\\t.reg .pred p;\\n\\tmbarrier.test_wait.parity.shared::cta.b64 p, [%1], 0;\\n\\t'
                      f'selp.u32 %0, 1, 0, p;\\n\\t@!p nanosleep.u32 64;\\n\\t}}" : "=r"(ok) '
                      f': "r"(to_shared(&mbar[{midx[n]} * 256 + lslot])) : "memory");\n    }}\n')
    for th in t.threads:
        if any(i.op == "cp" and "bulk" in i.quals and "prefetch" not in i.quals for i in th.instrs):
            drain += f'    if (role == {th.tid}) asm volatile("cp.async.bulk.wait_group 0;" ::: "memory");\n'
    if drain and exit_bar:
        drain += exit_bar
    src = (f"// Generated by tools/litmus/to_cuda.py from tests/litmus/{tid}.litmus. Do not edit.\n"
           + "".join(f"// {ln}\n" for ln in t.format().splitlines()) + KERNEL_HEAD
           + f"struct L {{\n{fields}}};\n\n" + "\n".join(bodies)
           + KERNEL_MAIN87.format(ngloc=max(len(gl), 1), nregs=max(len(slots), 1), nroles=len(t.threads), setup=setup,
                                  salign=sw * 4, swords=f"{max(nsh, 1)} * {ns} * {sw}" if sw != 4 else "4 * 256 * 4",
                                  cluster_bar=('        asm volatile("barrier.cluster.arrive;\\n\\tbarrier.cluster.wait;" ::: "memory");\n'
                                               if cluster_bar else ""),
                                  loc_init=loc_init, exit_none=("    " + exit_bar) if exit_bar else "",
                                  exit_role=exit_bar + final + drain,
                                  xparam=",\n                                                       unsigned long long adelta"
                                  if aliases else "",
                                  extra=("    __shared__ __align__(128) unsigned wgA[512];\n"
                                         "    __shared__ __align__(128) unsigned wgB[128];\n") if wga or wgb else "",
                                  dkey="(slot >> 5)" if widths else "slot",
                                  switch="".join(f"    case {k}: role{k}(l, out); break;\n" for k in range(len(t.threads)))))
    spec = "\n".join([f"# Generated by tools/litmus/to_cuda.py from tests/litmus/{tid}.litmus", "kernel litmus",
                      f"roles {len(t.threads)}", f"placement {place}", f"nregs {len(slots)}", f"ngloc {len(gl)}",
                      f"cluster_barrier {int(cluster_bar)}",
                      *(["warp_barrier 1"] if warp_bar and not cluster_bar else []),
                      *(["dsmem 1"] if dsmem else []),
                      *([f"uniform {' '.join(map(str, widths))}"] if widths else []),
                      *([f"grid {k} {g}" for k, g in enumerate(grids)] if multigrid else []),
                      *(["alias 1"] if aliases else []),
                      *[f"tmap {gl.index(tm)} {gl.index(src)}" for tm, (src, _) in tmaps.items()],
                      *[f"group {k} {g}" for k, g in enumerate(groups) if place == "mixed"],
                      *[f"init {gl.index(n)} {init[n]}" for n in gl if init[n] and place != "same-cta" and n not in tmaps],
                      *[f"init {gl.index(n)} {v} {w}" for n, v, w in extra_init],
                      *[f"reg {n} P{k}:{r}" if k >= 0 else f"reg {n} {r}" for n, (k, r) in enumerate(slots)],
                      *[f"gloc {n} {loc}" for n, loc in enumerate(gl)]]) + "\n"
    return src, spec


KERNEL_MAIN87 = r"""
#define NGLOC {ngloc}
#define NREGS {nregs}
#define NROLES {nroles}

extern "C" __global__ void __launch_bounds__(256) litmus(unsigned *mem, unsigned *res, unsigned *place,
                                                       const unsigned *assign, const unsigned *locoff,
                                                       unsigned *scratch, unsigned scratch_mask,
                                                       unsigned stress_iters, unsigned delay_mask{xparam}) {{
    __shared__ __align__(16) unsigned long long mbar[2 * 256];
    __shared__ __align__({salign}) unsigned sbuf[{swords}];
{extra}    unsigned slot = blockIdx.x * blockDim.x + threadIdx.x;
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
    unsigned d = ({dkey} * 2246822519u >> 13) & delay_mask;
    if (d)  /* a start delay; an empty loop would not do, ptxas removes it */
        asm volatile("nanosleep.u32 %0;" :: "r"(d) : "memory");
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
            gen = generate87 if tid.startswith(("ptx/kamui/ptx87/", "ptx/imported/", "ptx/kamui/features/",
                                                "ptx/kamui/idioms/")) else generate
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

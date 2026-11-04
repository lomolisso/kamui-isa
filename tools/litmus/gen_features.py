#!/usr/bin/env python3
"""Generate the per-feature litmus tests in tests/litmus/ptx/kamui/features/.

    python tools/litmus/gen_features.py            # write the tests
    python tools/litmus/gen_features.py --check    # fail if a committed test differs or is missing

The families of gen_families.py exercise plain loads, stores and fences. These tests exercise every other memory
feature of models/ptx87/coverage.yaml, so that each one is used in enough tests, with both verdicts, and with
every scope, state space and placement where it is valid (the bar of tools/litmus/scorecard.py). Folders:

- `ldst/`: loads and stores in every state space: global, shared memory of the own CTA (`shared::cta`), and
  distributed shared memory (`shared::cluster`: the own CTA's shared memory through the cluster window, or
  another CTA's); `.volatile`, `.mmio`, `ld.global.nc`, `ldu`, `.local`, `.const`, `.param`, cache operators;
- `rmw/`: every `atom` and `red` operation, order, scope and state space; `.b128`, half and vector forms;
- `fence/`: `membar`;
- `bar/`: CTA barriers (`bar.arrive`, `barrier.sync`, named barriers, `bar.warp.sync`) and cluster barriers;
- `mbarrier/`: arrive, expect-tx and complete-tx, waits by parity and by token, local and remote objects;
- `async/`: `cp.async`, bulk copies, multicast, tensor copies, `st.async`/`red.async`, proxy fences, tensor maps;
- `wgmma/`: `wgmma` fences, groups and operand reads, `ldmatrix`/`stmatrix`;
- `misc/`: `griddepcontrol`, `multimem`, `discard`, prefetches and cache policies.

A test is named after its shape and variant, for example `ldst/MP+rel-acq.cluster+dsmem-remote-reader`. The
verdicts come from the models (tools/litmus/run_formal.py); the description says what the test asks.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import litmus  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tests" / "litmus" / "ptx" / "kamui" / "features"
SCOPES = ["cta", "cluster", "gpu", "sys"]
FILES: dict[Path, str] = {}

# ------------------------------------------------------------------------------------------------- builder

REG = re.compile(r"\br\d+\b")
IDENT = re.compile(r"^[A-Za-z_]\w*$")


def test(folder: str, name: str, desc: str, threads: list, cond: str, init: list[str] = (),
         where: list[tuple] | None = None) -> None:
    """Add one test. `threads`: lists of instructions; `where`: (cta, cluster[, gpu[, grid]]) per thread
    (default all in CTA 0 of cluster 0); `init`: declarations beyond the plain zero ones, which are added for
    every other location and register."""
    where = where or [(0, 0)] * len(threads)
    decl = list(init)
    named = {re.split(r"[=\s\[@]", d.strip())[0] for d in decl}
    locs = []
    for body in threads:
        for ins in body:
            parts = ins.split(None, 1)
            for a in (parts[1].split(",") if len(parts) > 1 else []):
                for tok in a.strip().split("+"):
                    tok = re.sub(r"\[\d+\]$", "", tok.strip())
                    if IDENT.match(tok) and not REG.fullmatch(tok) and tok not in named and tok not in locs:
                        locs.append(tok)
    decl += [f"{loc}=0" for loc in locs]
    for k, body in enumerate(threads):
        regs = []
        for ins in body:
            for r in REG.findall(ins):
                if r not in regs:
                    regs.append(r)
        decl += [f"P{k}:{r}=0" for r in regs if f"P{k}:{r}" not in "".join(init)]
    t = litmus.Litmus(arch="PTX", name=name.split("/")[-1], comments=f'"{desc}"', init=decl, threads=[],
                      quantifier="exists", cond_text=cond, condition=None)
    for k, (body, w) in enumerate(zip(threads, where)):
        cta, cl = w[0], w[1]
        gpu = w[2] if len(w) > 2 else 0
        grid = w[3] if len(w) > 3 else None
        t.threads.append(litmus.Thread(k, cta, gpu, cl, [litmus.parse_instr(i) for i in body], grid))
    text = t.format()
    litmus.parse(text, name)
    path = OUT / folder / f"{name}.litmus"
    assert path not in FILES, path
    FILES[path] = text


# Where two threads' data and flag live, and how each thread reaches them. Each entry: placement of the writer
# (thread 0) and the reader (thread 1), declarations, the writer's and the reader's state-space qualifier.
LOCS = {
    "global+same-cta": ([(0, 0), (0, 0)], [], ".global", ".global", "global memory, both threads in one CTA"),
    "global+same-cluster": ([(0, 0), (1, 0)], [], ".global", ".global",
                            "global memory, the threads in two CTAs of one cluster"),
    "global+diff-cluster": ([(0, 0), (1, 1)], [], ".global", ".global", "global memory, the threads in two clusters"),
    "shared-cta": ([(0, 0), (0, 0)], ["@cta 0"], ".shared::cta", ".shared::cta",
                   "the shared memory of the threads' CTA"),
    "dsmem-local": ([(0, 0), (0, 0)], ["@cta 0"], ".shared::cluster", ".shared::cluster",
                    "the own CTA's shared memory through the cluster window"),
    "dsmem-remote-reader": ([(0, 0), (1, 0)], ["@cta 0"], ".shared::cta", ".shared::cluster",
                            "the writer's shared memory, read from another CTA of the cluster"),
    "dsmem-remote-writer": ([(0, 0), (1, 0)], ["@cta 1"], ".shared::cluster", ".shared::cta",
                            "the reader's shared memory, written from another CTA of the cluster"),
}


def decls(loc_kind: str, *names: str, values: dict | None = None) -> list[str]:
    owner = LOCS[loc_kind][1]
    values = values or {}
    return [f"{n}={values.get(n, 0)}" + (f" {owner[0]}" if owner else "") for n in names]


def ld(sem: str, scope: str, sp: str, reg: str, loc: str) -> str:
    return f"ld.weak{sp} {reg}, {loc}" if sem == "weak" else f"ld.{sem}.{scope}{sp} {reg}, {loc}"


def st(sem: str, scope: str, sp: str, loc: str, val) -> str:
    return f"st.weak{sp} {loc}, {val}" if sem == "weak" else f"st.{sem}.{scope}{sp} {loc}, {val}"


# --------------------------------------------------------------------------------------- loads and stores

def gen_ldst() -> None:
    for lk, (where, _, ws, rs, what) in LOCS.items():
        for s in SCOPES:
            for v, (fw, fr) in {"relaxed": ("relaxed", "relaxed"), "rel-acq": ("release", "acquire")}.items():
                test("ldst", f"MP+{v}.{s}+{lk}", f"Message passing in {what}; flag {fw}/{fr} at .{s}",
                     [[st("weak", s, ws, "x", 1), st(fw, s, ws, "f", 1)],
                      [ld(fr, s, rs, "r0", "f"), ld("weak", s, rs, "r1", "x")]],
                     "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x", "f"), where)
            test("ldst", f"CoRR+relaxed.{s}+{lk}", f"Two relaxed reads of one location in {what}, at .{s}",
                 [[st("relaxed", s, ws, "x", 1)], [ld("relaxed", s, rs, "r0", "x"), ld("relaxed", s, rs, "r1", "x")]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x"), where)
            test("ldst", f"SB+fence.sc.{s}+{lk}", f"Store buffering in {what} with fence.sc.{s}",
                 [[st("relaxed", s, ws, "x", 1), f"fence.sc.{s}", ld("relaxed", s, ws, "r0", "y")],
                  [st("relaxed", s, rs, "y", 1), f"fence.sc.{s}", ld("relaxed", s, rs, "r1", "x")]],
                 "P0:r0 == 0 /\\ P1:r1 == 0", decls(lk, "x", "y"), where)
            test("ldst", f"LB+relaxed.{s}+{lk}", f"Load buffering in {what}, relaxed at .{s}",
                 [[ld("relaxed", s, ws, "r0", "x"), st("relaxed", s, ws, "y", 1)],
                  [ld("relaxed", s, rs, "r1", "y"), st("relaxed", s, rs, "x", 1)]],
                 "P0:r0 == 1 /\\ P1:r1 == 1", decls(lk, "x", "y"), where)
    # .volatile (relaxed at .sys, no release or acquire) and .mmio (relaxed .sys on global memory)
    vol_locs = ["global+same-cta", "global+same-cluster", "global+diff-cluster", "shared-cta", "dsmem-local",
                "dsmem-remote-reader", "dsmem-remote-writer"]
    for lk in vol_locs:
        where, _, ws, rs, what = LOCS[lk]
        test("ldst", f"MP+volatile+{lk}", f"Message passing in {what}, the flag volatile (no release/acquire)",
             [[st("weak", "", ws, "x", 1), f"st.volatile{ws} f, 1"], [f"ld.volatile{rs} r0, f", ld("weak", "", rs, "r1", "x")]],
             "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x", "f"), where)
        test("ldst", f"MP+volatile+fences+{lk}", f"Message passing in {what}, a volatile flag with fence.acq_rel.sys",
             [[st("weak", "", ws, "x", 1), "fence.acq_rel.sys", f"st.volatile{ws} f, 1"],
              [f"ld.volatile{rs} r0, f", "fence.acq_rel.sys", ld("weak", "", rs, "r1", "x")]],
             "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x", "f"), where)
        test("ldst", f"CoRR+volatile+{lk}", f"Two volatile reads of one location in {what}",
             [[f"st.volatile{ws} x, 1"], [f"ld.volatile{rs} r0, x", f"ld.volatile{rs} r1, x"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x"), where)
    for lk in ["global+same-cta", "global+same-cluster", "global+diff-cluster"]:
        where, _, _, _, what = LOCS[lk]
        test("ldst", f"MP+mmio+{lk}", f"Message passing in {what}, the flag .mmio.relaxed.sys",
             [["st.weak.global x, 1", "st.mmio.relaxed.sys.global f, 1"],
              ["ld.mmio.relaxed.sys.global r0, f", "ld.weak.global r1, x"]], "P1:r0 == 1 /\\ P1:r1 == 0", [], where)
        test("ldst", f"MP+mmio+fences+{lk}", f"Message passing in {what}, an .mmio flag with fence.acq_rel.sys",
             [["st.weak.global x, 1", "fence.acq_rel.sys", "st.mmio.relaxed.sys.global f, 1"],
              ["ld.mmio.relaxed.sys.global r0, f", "fence.acq_rel.sys", "ld.weak.global r1, x"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", [], where)
        test("ldst", f"CoRR+mmio+{lk}", f"Two .mmio reads of one location in {what}",
             [["st.mmio.relaxed.sys.global x, 1"], ["ld.mmio.relaxed.sys.global r0, x", "ld.mmio.relaxed.sys.global r1, x"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", [], where)
        # non-coherent and read-only loads: may miss written data, never invent a value
        for name, form in (("ld.global.nc", "ld.global.nc"), ("ldu", "ldu.global")):
            test("ldst", f"MP+{name}+{lk}", f"Message passing in {what}, the data read with {form}",
                 [["st.weak.global x, 1", "st.release.gpu.global f, 1"], ["ld.acquire.gpu.global r0, f", f"{form} r1, x"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", [], where)
            test("ldst", f"CoWR+{name}+{lk}", f"A thread stores, then reads back with {form} ({what})",
                 [["st.weak.global x, 1", f"{form} r0, x"], ["st.weak.global y, 1"]], "P0:r0 == 0", [], where)
            test("ldst", f"value+{name}+{lk}", f"{form} returns only values some write committed ({what})",
                 [["st.weak.global x, 1"], [f"{form} r0, x"]], "P1:r0 == 7", [], where)
    # the thread-private, constant and parameter state spaces
    for s in ["weak", "relaxed.cta", "relaxed.gpu"]:
        sem = s.split(".")
        stq = "st.weak.local" if s == "weak" else f"st.{sem[0]}.{sem[1]}.local"
        ldq = "ld.weak.local" if s == "weak" else f"ld.{sem[0]}.{sem[1]}.local"
        tag = s.replace(".", "-")
        test("ldst", f"CoWR+local+{tag}", "A thread stores to its local memory and reads it back",
             [[f"{stq} l, 1", f"{ldq} r0, l"]], "P0:r0 == 0")
        test("ldst", f"CoWW+local+{tag}", "Two stores to local memory, then a read: the last one is read",
             [[f"{stq} l, 1", f"{stq} l, 2", f"{ldq} r0, l"]], "P0:r0 == 1")
        test("ldst", f"local+private+{tag}", "Local memory is private: another thread's store to its own local "
             "location of the same name is not seen", [[f"{stq} l, 1", f"{ldq} r0, l"], [f"{stq} m, 2"]], "P0:r0 == 1")
    for sp in ("const", "param"):
        for lk in ["global+same-cta", "global+same-cluster", "global+diff-cluster"]:
            where = LOCS[lk][0]
            test("ldst", f"{sp}+initial+{lk}", f"Loads from the read-only .{sp} space return the initial value",
                 [[f"ld.{sp} r0, c"], [f"ld.{sp} r1, c"]], "P0:r0 == 3 /\\ P1:r1 == 3", ["c=3"], where)
            test("ldst", f"{sp}+other+{lk}", f"A load from .{sp} never returns a value the location never had",
                 [[f"ld.{sp} r0, c"], [f"ld.{sp} r1, c"]], "P0:r0 == 0 \\/ P1:r1 == 0", ["c=3"], where)
        test("ldst", f"{sp}+with-global-traffic", f".{sp} loads next to global message passing",
             [["st.weak.global x, 1", "st.release.gpu f, 1"], ["ld.acquire.gpu r0, f", f"ld.{sp} r1, c", "ld.weak r2, x"]],
             "P1:r0 == 1 /\\ P1:r2 == 0", ["c=3"], [(0, 0), (1, 0)])
        test("ldst", f"{sp}+value-with-global-traffic", f"The .{sp} load keeps its value whatever other threads do",
             [["st.weak.global x, 1", "st.release.gpu f, 1"], ["ld.acquire.gpu r0, f", f"ld.{sp} r1, c"]],
             "P1:r1 != 3", ["c=3"], [(0, 0), (1, 0)])
    # cache operators and eviction hints change no ordering: each pairs an allowed and a forbidden MP
    hints = {"ld.cache_op": [("ld", q) for q in ("ca", "cg", "cs", "lu", "cv")],
             "st.cache_op": [("st", q) for q in ("wb", "cg", "cs", "wt")],
             "ld.cache_hint": [("ld", q) for q in ("L1::evict_first", "L1::evict_last", "L1::no_allocate",
                                                   "L1::evict_normal", "L2::cache_hint")]}
    for _, forms in hints.items():
        for kind, q in forms:
            tag = q.replace("::", "-")
            for v, (fw, fr) in {"weak": ("relaxed", "relaxed"), "rel-acq": ("release", "acquire")}.items():
                data_st = f"st.weak.global.{q} x, 1" if kind == "st" else "st.weak.global x, 1"
                data_ld = f"ld.weak.global.{q} r1, x" if kind == "ld" else "ld.weak.global r1, x"
                test("ldst", f"MP+{kind}.{tag}+{v}", f"Message passing with the data {'stored' if kind == 'st' else 'loaded'} "
                     f"with .{q}; flag {fw}/{fr}", [[data_st, f"st.{fw}.gpu f, 1"], [f"ld.{fr}.gpu r0, f", data_ld]],
                     "P1:r0 == 1 /\\ P1:r1 == 0", [], [(0, 0), (1, 0)])


# ------------------------------------------------------------------------------------- atomics, reductions

# op -> (initial value, operands of the writer, value after one operation, reader operands keeping the value)
OPS = {"add": (0, "1", 1), "and": (3, "1", 1), "or": (0, "1", 1), "xor": (0, "1", 1), "min": (2, "1", 1),
       "max": (0, "1", 1), "inc": (0, "5", 1), "dec": (2, "5", 1), "exch": (0, "1", 1), "cas": (0, "0, 1", 1)}
PLACES = {"same-cta": [(0, 0), (0, 0)], "same-cluster": [(0, 0), (1, 0)], "diff-cluster": [(0, 0), (1, 1)]}


def gen_rmw() -> None:
    for op, (ini, operand, after) in OPS.items():
        for s in SCOPES:
            for pk, where in PLACES.items():
                test("rmw", f"LU+{op}.{s}+{pk}", f"Two relaxed .{s} atom.{op} on one global location: can both read "
                     "the initial value (a lost update)?",
                     [[f"atom.relaxed.{s}.global.{op} r0, x, {operand}"], [f"atom.relaxed.{s}.global.{op} r1, x, {operand}"]],
                     f"P0:r0 == {ini} /\\ P1:r1 == {ini}", [f"x={ini}"], where)
        for v, sem in {"relaxed": "relaxed", "release": "release"}.items():
            test("rmw", f"MP+{op}.{v}-writer", f"Message passing where the flag is set by atom.{sem}.gpu.{op}",
                 [["st.weak x, 1", f"atom.{sem}.gpu.{op} r9, f, {operand}"], ["ld.acquire.gpu r0, f", "ld.weak r1, x"]],
                 f"P1:r0 == {after} /\\ P1:r1 == 0", [f"f={ini}"], [(0, 0), (1, 0)])
        test("rmw", f"MP+{op}.acquire-reader", f"Message passing where the flag is read by atom.acquire.gpu.{op}",
             [["st.weak x, 1", f"st.release.gpu f, {after}"], [f"atom.acquire.gpu.{op} r0, f, {operand}", "ld.weak r1, x"]],
             f"P1:r0 == {after} /\\ P1:r1 == 0", [f"f={ini}"], [(0, 0), (1, 0)])
    # orders and scopes of atom, with every placement
    for s in SCOPES:
        for pk, where in PLACES.items():
            for sem, (w, r) in {"acquire": ("st.release", "atom.acquire"), "release": ("atom.release", "ld.acquire"),
                                "acq_rel": ("atom.acq_rel", "atom.acq_rel")}.items():
                wi = f"{w}.{s}.add r9, f, 1" if w.startswith("atom") else f"{w}.{s} f, 1"
                ri = f"{r}.{s}.add r0, f, 0" if r.startswith("atom") else f"{r}.{s} r0, f"
                test("rmw", f"MP+atom-{sem}.{s}+{pk}", f"Message passing with atom.{sem} at .{s}",
                     [["st.weak x, 1", wi], [ri, "ld.weak r1, x"]], "P1:r0 == 1 /\\ P1:r1 == 0", [], where)
    # state spaces: shared memory of the own CTA and distributed shared memory
    for lk in ["shared-cta", "dsmem-local", "dsmem-remote-reader", "dsmem-remote-writer"]:
        where, _, ws, rs, what = LOCS[lk]
        for s in SCOPES:
            test("rmw", f"LU+add.{s}+{lk}", f"Two relaxed .{s} atom.add on one location in {what}",
                 [[f"atom.relaxed.{s}{ws}.add r0, x, 1"], [f"atom.relaxed.{s}{rs}.add r1, x, 1"]],
                 "P0:r0 == 0 /\\ P1:r1 == 0", decls(lk, "x"), where)
            test("rmw", f"MP+atom-release.{s}+{lk}", f"Message passing in {what}, the flag set by atom.release.{s}",
                 [[st("weak", s, ws, "x", 1), f"atom.release.{s}{ws}.exch r9, f, 1"],
                  [ld("acquire", s, rs, "r0", "f"), ld("weak", s, rs, "r1", "x")]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x", "f"), where)
            test("rmw", f"LU+red.{s}+{lk}", f"Two relaxed .{s} red.add on one location in {what}",
                 [[f"red.relaxed.{s}{ws}.add x, 1"], [f"red.relaxed.{s}{rs}.add x, 1"]], "x == 1", decls(lk, "x"), where)
            test("rmw", f"MP+red-release.{s}+{lk}", f"Message passing in {what}, the flag set by red.release.{s}",
                 [[st("weak", s, ws, "x", 1), f"red.release.{s}{ws}.add f, 1"],
                  [ld("acquire", s, rs, "r0", "f"), ld("weak", s, rs, "r1", "x")]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x", "f"), where)
    # red in global memory, with and without a state space qualifier
    for s in SCOPES:
        for pk, where in PLACES.items():
            test("rmw", f"LU+red.{s}+{pk}", f"Two relaxed .{s} red.add on one global location",
                 [[f"red.relaxed.{s}.global.add x, 1"], [f"red.relaxed.{s}.add x, 1"]], "x == 1", [], where)
            test("rmw", f"MP+red-release.{s}+{pk}", f"Message passing, the flag set by red.release.{s}",
                 [["st.weak x, 1", f"red.release.{s}.add f, 1"], [f"ld.acquire.{s} r0, f", "ld.weak r1, x"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", [], where)
    # 128-bit, half-precision and vector atomics
    for s in SCOPES:
        for pk, where in PLACES.items():
            test("rmw", f"LU+cas.b128.{s}+{pk}", f"Two .{s} 128-bit compare-and-swaps: can both succeed?",
                 [[f"atom.relaxed.{s}.cas.b128 r0, x, 0, 1"], [f"atom.relaxed.{s}.cas.b128 r1, x, 0, 2"]],
                 "P0:r0 == 0 /\\ P1:r1 == 0", [], where)
            test("rmw", f"LU+add.f16.{s}+{pk}", f"Two .{s} half-precision atom.add (noftz.f16): a lost update?",
                 [[f"atom.relaxed.{s}.global.add.noftz.f16 r0, x, 1"], [f"atom.relaxed.{s}.global.add.noftz.f16 r1, x, 1"]],
                 "P0:r0 == 0 /\\ P1:r1 == 0", [], where)
            test("rmw", f"LU+add.v2.{s}+{pk}", f"Two .{s} vector atom.add (v2.f32) on the same two elements",
                 [[f"atom.relaxed.{s}.global.v2.f32.add r0, r1, x, y, 1, 1"],
                  [f"atom.relaxed.{s}.global.v2.f32.add r2, r3, x, y, 1, 1"]],
                 "P0:r0 == 0 /\\ P1:r2 == 0", [], where)
            test("rmw", f"tear+red.v2.{s}+{pk}", f"A .{s} vector red.add (v2.f32) and a vector atom.add that reads "
                 "both elements: can it see one element updated and not the other?",
                 [[f"red.relaxed.{s}.global.v2.f32.add x, y, 1, 1"], [f"atom.relaxed.{s}.global.v2.f32.add r0, r1, x, y, 0, 0"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", [], where)
        test("rmw", f"CoWR+red.v2.{s}", f"A thread's .{s} vector red.add, then its own loads of both elements: does "
             "it miss its own update?",
             [[f"red.relaxed.{s}.global.v2.f32.add x, y, 1, 1", f"ld.relaxed.{s}.global r0, x", f"ld.relaxed.{s}.global r1, y"]],
             "P0:r0 == 0 \\/ P0:r1 == 0")
        test("rmw", f"MP+cas.b128.release.{s}", f"Message passing where a 128-bit cas.release.{s} sets the flag",
             [["st.weak x, 1", f"atom.release.{s}.cas.b128 r9, f, 0, 1"], [f"ld.acquire.{s} r0, f", "ld.weak r1, x"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", [], [(0, 0), (1, 0)])


# --------------------------------------------------------------------------------------------------- fences

def gen_fence() -> None:
    for lvl, scope in (("cta", "cta"), ("gl", "gpu"), ("sys", "sys")):
        for pk, where in PLACES.items():
            test("fence", f"SB+membar.{lvl}+{pk}", f"Store buffering with membar.{lvl} (fence.sc.{scope})",
                 [[f"st.relaxed.{scope} x, 1", f"membar.{lvl}", f"ld.relaxed.{scope} r0, y"],
                  [f"st.relaxed.{scope} y, 1", f"membar.{lvl}", f"ld.relaxed.{scope} r1, x"]],
                 "P0:r0 == 0 /\\ P1:r1 == 0", [], where)
            test("fence", f"MP+membar.{lvl}+{pk}", f"Message passing with membar.{lvl} on both sides",
                 [["st.weak x, 1", f"membar.{lvl}", f"st.relaxed.{scope} f, 1"],
                  [f"ld.relaxed.{scope} r0, f", f"membar.{lvl}", "ld.weak r1, x"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", [], where)


# ------------------------------------------------------------------------------------------------- barriers

def gen_bar() -> None:
    for sp, init, q in (("global", [], ""), ("shared", ["x=0 @cta 0", "y=0 @cta 0"], ".shared::cta")):
        for bid in (0, 1, 3):
            test("bar", f"MP+bar.arrive.{bid}+{sp}", f"A producer arrives on barrier {bid} (bar.arrive), the consumer "
                 "waits on it (bar.sync)", [[f"st.weak{q} x, 1", f"bar.arrive {bid}, 2"], [f"bar.sync {bid}, 2", f"ld.weak{q} r0, x"]],
                 "P1:r0 == 0", init)
            test("bar", f"arrive-no-acquire.{bid}+{sp}", f"bar.arrive {bid} does not wait: the arriving thread may "
                 "miss data written before the other thread's bar.sync",
                 [[f"bar.arrive {bid}, 2", f"ld.weak{q} r0, y"], [f"st.weak{q} y, 1", f"bar.sync {bid}, 2"]],
                 "P0:r0 == 0", init)
            test("bar", f"MP+barrier.sync.{bid}+{sp}", f"Message passing through barrier.sync {bid}",
                 [[f"st.weak{q} x, 1", f"barrier.sync {bid}"], [f"barrier.sync {bid}", f"ld.weak{q} r0, x"]], "P1:r0 == 0", init)
            test("bar", f"MP+barrier.sync.aligned.{bid}+{sp}", f"Message passing through barrier.sync.aligned {bid}",
                 [[f"st.weak{q} x, 1", f"barrier.sync.aligned {bid}"], [f"barrier.sync.aligned {bid}", f"ld.weak{q} r0, x"]],
                 "P1:r0 == 0", init)
            test("bar", f"SB+barrier.sync.{bid}+{sp}", f"Each thread stores, meets at barrier.sync {bid}, then reads "
                 "the other's location", [[f"st.weak{q} x, 1", f"barrier.sync {bid}", f"ld.weak{q} r0, y"],
                                          [f"st.weak{q} y, 1", f"barrier.sync {bid}", f"ld.weak{q} r1, x"]],
                 "P0:r0 == 0 \\/ P1:r1 == 0", init)
            test("bar", f"after-barrier-race.{bid}+{sp}", f"A store after barrier.sync {bid} races with the other "
                 "thread's load after it", [[f"barrier.sync {bid}", f"st.weak{q} x, 1"], [f"barrier.sync {bid}", f"ld.weak{q} r0, x"]],
                 "P1:r0 == 0", init)
        for mask, who in ((3, "both threads"), (-1, "the full warp")):
            test("bar", f"MP+bar.warp.sync.{'all' if mask == -1 else mask}+{sp}", f"Message passing through "
                 f"bar.warp.sync with {who} in the mask", [[f"st.weak{q} x, 1", f"bar.warp.sync {mask}"],
                                                          [f"bar.warp.sync {mask}", f"ld.weak{q} r0, x"]], "P1:r0 == 0", init)
            test("bar", f"after-bar.warp.sync.{'all' if mask == -1 else mask}+{sp}", "A store after bar.warp.sync "
                 "races with the other thread's load", [[f"bar.warp.sync {mask}", f"st.weak{q} x, 1"],
                                                        [f"bar.warp.sync {mask}", f"ld.weak{q} r0, x"]], "P1:r0 == 0", init)
    # cluster barriers: arrive variants, with data in global or in another CTA's shared memory
    arrives = {"default": (["barrier.cluster.arrive"], []), "release": (["barrier.cluster.arrive.release"], []),
               "relaxed": (["barrier.cluster.arrive.relaxed"], []),
               "relaxed+fence.acq_rel": (["fence.acq_rel.cluster", "barrier.cluster.arrive.relaxed"], []),
               "relaxed+fence.release": (["fence.release.cluster", "barrier.cluster.arrive.relaxed"], [])}
    for sp, init, wq, rq in (("global", [], "", ""), ("dsmem", ["x=0 @cta 1"], ".shared::cluster", ".shared::cta"),
                             ("shared", ["x=0 @cta 0"], ".shared::cta", ".shared::cta")):
        for pk, where in (("same-cta", [(0, 0), (0, 0)]), ("same-cluster", [(0, 0), (1, 0)])):
            if sp == "shared" and pk != "same-cta" or sp == "dsmem" and pk != "same-cluster":
                continue
            for a, (seq, _) in arrives.items():
                test("bar", f"MP+barrier.cluster.{a}+{sp}+{pk}", f"Message passing through a cluster barrier, "
                     f"arrive {a}", [[f"st.weak{wq} x, 1"] + seq + ["barrier.cluster.wait"],
                                     ["barrier.cluster.arrive", "barrier.cluster.wait.acquire", f"ld.weak{rq} r0, x"]],
                     "P1:r0 == 0", init, where)


# ------------------------------------------------------------------------------------------------ mbarrier

def gen_mbarrier() -> None:
    # message passing through an mbarrier: the producer arrives, the consumer waits (b lives in the consumer's CTA)
    for pk, where, arrive_sp in (("local", [(0, 0), (0, 0)], ""), ("remote", [(0, 0), (1, 0)], ".shared::cluster")):
        for scope in ("cta", "cluster"):
            for asem in ("release", "relaxed"):
                for wait in ("test_wait", "try_wait"):
                    for wsem in ("acquire", "relaxed"):
                        name = f"MP+mbarrier.{asem}.{wait}.{wsem}.{scope}+{pk}"
                        test("mbarrier", name, f"Message passing through an mbarrier in the consumer's CTA: arrive "
                             f".{asem}.{scope}{' from another CTA' if pk == 'remote' else ''}, {wait}.parity.{wsem}.{scope}",
                             [["st.weak x, 1", f"mbarrier.arrive.{asem}.{scope}{arrive_sp} b"],
                              [f"mbarrier.{wait}.parity.{wsem}.{scope} r0, b, 0", "ld.weak r1, x"]],
                             "P1:r0 == 1 /\\ P1:r1 == 0", [f"b=mbarrier(1) @cta {where[1][0]}"], where)
            # waits by state token (the consumer arrives too and waits for the phase of its own arrive)
            for wsem in ("acquire", "relaxed"):
                test("mbarrier", f"MP+mbarrier.token.{wsem}.{scope}+{pk}", f"Message passing through an mbarrier "
                     f"of count 2, the consumer waiting by state token (.{wsem}.{scope})",
                     [["st.weak x, 1", f"mbarrier.arrive.release.{scope}{arrive_sp} b"],
                      [f"mbarrier.arrive.release.{scope} r5, b", f"mbarrier.test_wait.{wsem}.{scope} r0, b, r5", "ld.weak r1, x"]],
                     "P1:r0 == 1 /\\ P1:r1 == 0", [f"b=mbarrier(2) @cta {where[1][0]}"], where)
            # arrive_drop: the producer drops out of later phases
            test("mbarrier", f"MP+mbarrier.arrive_drop.{scope}+{pk}", "Message passing where the producer arrives "
                 "with arrive_drop", [["st.weak x, 1", f"mbarrier.arrive_drop.release.{scope}{arrive_sp} b"],
                                      [f"mbarrier.test_wait.parity.acquire.{scope} r0, b, 0", "ld.weak r1, x"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", [f"b=mbarrier(1) @cta {where[1][0]}"], where)
            test("mbarrier", f"phase+mbarrier.arrive_drop.{scope}+{pk}", "After arrive_drop the expected count "
                 "shrinks: the next phase completes with the other thread's arrive alone",
                 [[f"mbarrier.arrive_drop.relaxed.{scope}{arrive_sp} b"],
                  [f"mbarrier.test_wait.parity.relaxed.{scope} r0, b, 0", f"mbarrier.arrive.relaxed.{scope} b",
                   f"mbarrier.test_wait.parity.relaxed.{scope} r1, b, 1"]],
                 "P1:r0 == 0 /\\ P1:r1 == 1", [f"b=mbarrier(2) @cta {where[1][0]}"], where)
            # expect_tx and complete_tx: the phase completes only when the transaction count returns to zero
            test("mbarrier", f"MP+mbarrier.complete_tx.{scope}+{pk}", "The consumer's arrive.expect_tx sets a "
                 "transaction count that the producer's complete_tx clears",
                 [["st.weak x, 1", f"mbarrier.complete_tx.relaxed.{scope}{arrive_sp} b, 1"],
                  [f"mbarrier.arrive.expect_tx.release.{scope} b, 1", f"mbarrier.test_wait.parity.acquire.{scope} r0, b, 0",
                   "ld.weak r1, x"]], "P1:r0 == 1 /\\ P1:r1 == 0", [f"b=mbarrier(1) @cta {where[1][0]}"], where)
            test("mbarrier", f"pending-tx+mbarrier.expect_tx.{scope}+{pk}", "expect_tx without the matching "
                 "complete_tx keeps the phase open", [[f"mbarrier.expect_tx.relaxed.{scope}{arrive_sp} b, 1"],
                                                      [f"mbarrier.arrive.relaxed.{scope} b",
                                                       f"mbarrier.test_wait.parity.relaxed.{scope} r0, b, 0"]],
                 "P1:r0 == 1", [f"b=mbarrier(1) @cta {where[1][0]}"], where)
            test("mbarrier", f"MP+mbarrier.expect_tx.{scope}+{pk}", "expect_tx by one thread, complete_tx and "
                 "arrive by another", [["st.weak x, 1", f"mbarrier.complete_tx.relaxed.{scope}{arrive_sp} b, 1",
                                        f"mbarrier.arrive.release.{scope}{arrive_sp} b"],
                                       [f"mbarrier.expect_tx.relaxed.{scope} b, 1",
                                        f"mbarrier.test_wait.parity.acquire.{scope} r0, b, 0", "ld.weak r1, x"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", [f"b=mbarrier(2) @cta {where[1][0]}"], where)
    # initialization: init in one thread, use in another, with and without fence.mbarrier_init and a barrier. The
    # arrive returns no state (a remote arrive cannot), so after a second barrier the owner waits on the phase.
    for scope, where, sp in (("cta", [(0, 0), (0, 0)], ""), ("cluster", [(0, 0), (1, 0)], ".shared::cluster")):
        sync = ["bar.sync 0"] if scope == "cta" else ["barrier.cluster.arrive.relaxed", "barrier.cluster.wait"]
        sync2 = ["bar.sync 0"] if scope == "cta" else ["barrier.cluster.arrive", "barrier.cluster.wait"]
        for fence_kind, f in (("fence", ["fence.mbarrier_init.release.cluster"]), ("no-fence", []),
                              ("fence.acq_rel", ["fence.acq_rel.cluster"])):
            test("mbarrier", f"init+{fence_kind}+use.{scope}", f"mbarrier.init in one thread, {fence_kind}, then an "
                 "arrive from another thread; after a second barrier the owner waits on the phase",
                 [["mbarrier.init.shared::cta b, 1"] + f + sync + sync2 + ["mbarrier.test_wait.parity.acquire.cta r0, b, 0"],
                  sync + [f"mbarrier.arrive.release.{scope}{sp} b"] + sync2],
                 "P0:r0 == 0", ["b=mbarrier() @cta 0"], where)
        test("mbarrier", f"init+inval+reinit.{scope}", "init, inval and init again in one thread, then use",
             [["mbarrier.init.shared::cta b, 1", "mbarrier.inval.shared::cta b", "mbarrier.init.shared::cta b, 1",
               "fence.mbarrier_init.release.cluster"] + sync + sync2 + ["mbarrier.test_wait.parity.acquire.cta r0, b, 0"],
              sync + [f"mbarrier.arrive.release.{scope}{sp} b"] + sync2],
             "P0:r0 == 0", ["b=mbarrier() @cta 0"], where)
    test("mbarrier", "inval+after-use", "An object invalidated after its last use: the use is defined",
         [["mbarrier.arrive.release.cta r0, b", "mbarrier.inval.shared::cta b"]], "P0:r0 != 0",
         ["b=mbarrier(1) @cta 0"], [(0, 0)])
    test("mbarrier", "inval+race", "An object invalidated while another thread of the CTA may still use it",
         [["mbarrier.inval.shared::cta b"], ["mbarrier.arrive.release.cta r0, b"]],
         "P1:r0 == 7", ["b=mbarrier(1) @cta 0"], [(0, 0), (0, 0)])


# -------------------------------------------------------------------------------------------- async copies

def gen_async() -> None:
    # cp.async (non-bulk): the copy reads at issue order, completes at a wait or at cp.async.mbarrier.arrive
    for size, kind in (("4", "ca"), ("16", "cg")):
        q = f"cp.async.{kind}.shared.global"
        test("async", f"CoWR+cp.async.{kind}+wait_all", "A thread stores, copies with cp.async, waits, reads the copy",
             [["st.weak.global g, 1", f"{q} d, g", "cp.async.wait_all", "ld.weak.shared r0, d"]], "P0:r0 == 0", ["d=0 @cta 0"])
        test("async", f"CoWR+cp.async.{kind}+wait_group", "The same with commit_group and wait_group 0",
             [["st.weak.global g, 1", f"{q} d, g", "cp.async.commit_group", "cp.async.wait_group 0", "ld.weak.shared r0, d"]],
             "P0:r0 == 0", ["d=0 @cta 0"])
        test("async", f"CoWR+cp.async.{kind}+no-wait", "Without a wait the copy may still be in flight",
             [["st.weak.global g, 1", f"{q} d, g", "ld.weak.shared r0, d"]], "P0:r0 == 1", ["d=0 @cta 0"])
        test("async", f"CoWR+cp.async.{kind}+wait_group1", "wait_group 1 leaves the newest group in flight",
             [["st.weak.global g, 1", f"{q} d, g", "cp.async.commit_group", "cp.async.wait_group 1", "ld.weak.shared r0, d"]],
             "P0:r0 == 1", ["d=0 @cta 0"])
        test("async", f"MP+cp.async.{kind}+acquire", "The copy is issued after an acquire of the producer's flag",
             [["st.weak.global g, 1", "st.release.gpu f, 1"],
              ["ld.acquire.gpu r0, f", f"{q} d, g", "cp.async.wait_all", "ld.weak.shared r1, d"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["d=0 @cta 1"], [(0, 0), (1, 0)])
        test("async", f"MP+cp.async.{kind}+bar.sync", "A copy waited for by one thread, read by another after bar.sync",
             [[f"{q} d, g", "cp.async.wait_all", "bar.sync 0"], ["bar.sync 0", "ld.weak.shared r0, d"]],
             "P1:r0 != 5", ["g=5", "d=0 @cta 0"])
        test("async", f"MP+cp.async.{kind}+no-wait+bar.sync", "The same without the wait",
             [[f"{q} d, g", "bar.sync 0"], ["bar.sync 0", "ld.weak.shared r0, d"]], "P1:r0 != 5", ["g=5", "d=0 @cta 0"])
        for noinc in ("", ".noinc"):
            cnt = 1 if noinc else 2
            test("async", f"MP+cp.async.{kind}.mbarrier.arrive{noinc}", "Completion signalled with "
                 f"cp.async.mbarrier.arrive{noinc}", [[f"{q} d, g", f"cp.async.mbarrier.arrive{noinc}.shared b"] +
                                                      ([] if noinc else ["mbarrier.arrive.release.cta b"]),
                                                      ["mbarrier.test_wait.parity.acquire.cta r0, b, 0", "ld.weak.shared r1, d"]],
                 "P1:r0 == 1 /\\ P1:r1 != 5", ["g=5", "d=0 @cta 0", f"b=mbarrier({cnt}) @cta 0"])
    # bulk copies global -> shared, completing on an mbarrier; the reader in the same or another CTA
    tma = "cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes"
    for scope, where, owner in (("cta", [(0, 0), (0, 0)], 0), ("cluster", [(0, 0), (1, 0)], 1)):
        test("async", f"TMA-load+same-thread.{scope}", "A bulk copy into the own CTA's shared memory, waited for "
             "on its mbarrier by the issuing thread", [[f"mbarrier.arrive.expect_tx.release.cta b, 1", f"{tma} d, g, b",
                                                        "mbarrier.try_wait.parity.acquire.cta r0, b, 0", "ld.weak.shared::cta r1, d"]],
             "P0:r0 == 1 /\\ P0:r1 != 5", ["g=5", "d=0 @cta 0", "b=mbarrier(1) @cta 0"], [(0, 0)])
        test("async", f"TMA-load+reader.{scope}", f"A bulk copy into CTA {owner}'s shared memory; a thread of that "
             "CTA waits on the mbarrier and reads", [[f"{tma} d, g, b"],
                                                    ["mbarrier.arrive.expect_tx.release.cta b, 1",
                                                     f"mbarrier.try_wait.parity.acquire.{scope} r0, b, 0",
                                                     "ld.weak.shared::cta r1, d"]],
             "P1:r0 == 1 /\\ P1:r1 != 5", ["g=5", f"d=0 @cta {owner}", f"b=mbarrier(1) @cta {owner}"], where)
        test("async", f"TMA-load+no-wait.{scope}", "The reader reads without waiting on the mbarrier",
             [[f"{tma} d, g, b"], ["ld.weak.shared::cta r1, d"]], "P1:r1 != 5",
             ["g=5", f"d=0 @cta {owner}", f"b=mbarrier(1) @cta {owner}"], where)
        test("async", f"TMA-load+source-acquire.{scope}", "The copy's source was written by another thread and "
             "acquired before the copy is issued", [["st.weak.global g, 5", "st.release.gpu f, 1"],
                                                    ["ld.acquire.gpu r0, f", "mbarrier.arrive.expect_tx.release.cta b, 1",
                                                     f"{tma} d, g, b", "mbarrier.try_wait.parity.acquire.cta r1, b, 0",
                                                     "ld.weak.shared::cta r2, d"]],
             "P1:r0 == 1 /\\ P1:r1 == 1 /\\ P1:r2 != 5", [f"d=0 @cta {owner}", f"b=mbarrier(1) @cta {owner}"],
             [(0, 0), (owner, 0)])
        test("async", f"TMA-load+source-no-acquire.{scope}", "The same with a relaxed read of the flag",
             [["st.weak.global g, 5", "st.release.gpu f, 1"],
              ["ld.relaxed.gpu r0, f", "mbarrier.arrive.expect_tx.release.cta b, 1", f"{tma} d, g, b",
               "mbarrier.try_wait.parity.acquire.cta r1, b, 0", "ld.weak.shared::cta r2, d"]],
             "P1:r0 == 1 /\\ P1:r1 == 1 /\\ P1:r2 != 5", [f"d=0 @cta {owner}", f"b=mbarrier(1) @cta {owner}"],
             [(0, 0), (owner, 0)])
    # bulk copies shared::cta -> shared::cluster (into another CTA) and shared -> global (stores)
    s2c = "cp.async.bulk.shared::cluster.shared::cta.mbarrier::complete_tx::bytes"
    for fence in ("", "fence.proxy.async.shared::cta"):
        tag = "+fence" if fence else "+no-fence"
        pre = [fence] if fence else []
        test("async", f"DSMEM-copy{tag}", "A thread writes its CTA's shared memory and copies it into another CTA "
             "with a bulk copy; a thread there waits and reads",
             [["st.weak.shared::cta s, 5"] + pre + [f"{s2c} d, s, b"],
              ["mbarrier.arrive.expect_tx.release.cta b, 1", "mbarrier.try_wait.parity.acquire.cluster r0, b, 0",
               "ld.weak.shared::cta r1, d"]],
             "P1:r0 == 1 /\\ P1:r1 != 5", ["s=0 @cta 0", "d=0 @cta 1", "b=mbarrier(1) @cta 1"], [(0, 0), (1, 0)])
        test("async", f"DSMEM-copy-war{tag}", "The source is overwritten right after the copy is issued",
             [["st.weak.shared::cta s, 5"] + pre + [f"{s2c} d, s, b", "st.weak.shared::cta s, 6"],
              ["mbarrier.arrive.expect_tx.release.cta b, 1", "mbarrier.try_wait.parity.acquire.cluster r0, b, 0",
               "ld.weak.shared::cta r1, d"]],
             "P1:r0 == 1 /\\ P1:r1 == 6", ["s=0 @cta 0", "d=0 @cta 1", "b=mbarrier(1) @cta 1"], [(0, 0), (1, 0)])
        for wait, wtag in (("cp.async.bulk.wait_group 0", "wait"), ("cp.async.bulk.wait_group.read 0", "wait.read"), (None, "no-wait")):
            body = ["st.weak.shared::cta s, 1"] + pre + ["cp.async.bulk.global.shared::cta.bulk_group g, s",
                                                          "cp.async.bulk.commit_group"] + ([wait] if wait else [])
            test("async", f"TMA-store{tag}+{wtag}", "A bulk store of shared memory to global memory, then a release "
                 "of a flag; another CTA acquires the flag and reads", [body + ["st.release.gpu f, 1"],
                                                                        ["ld.acquire.gpu r0, f", "ld.weak.global r1, g"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", ["s=0 @cta 0"], [(0, 0), (1, 0)])
            test("async", f"TMA-store-reuse{tag}+{wtag}", "The shared source is reused after the bulk store",
                 [body + ["st.weak.shared::cta s, 2", "st.release.gpu f, 1"], ["ld.acquire.gpu r0, f", "ld.weak.global r1, g"]],
                 "P1:r0 == 1 /\\ P1:r1 == 2", ["s=0 @cta 0"], [(0, 0), (1, 0)])
        test("async", f"reduce{tag}", "cp.reduce.async.bulk adds shared memory into global memory; another thread "
             "adds with a generic atomic", [["st.weak.shared::cta s, 1"] + pre +
                                            ["cp.reduce.async.bulk.global.shared::cta.bulk_group.add.u32 g, s",
                                             "cp.async.bulk.commit_group", "cp.async.bulk.wait_group 0"],
                                            ["red.relaxed.gpu.global.add g, 1"]],
             "g == 1", ["s=0 @cta 0"], [(0, 0), (1, 0)])
        test("async", f"MP+reduce{tag}", "A bulk reduction completed, then a flag released; the reader acquires it",
             [["st.weak.shared::cta s, 1"] + pre + ["cp.reduce.async.bulk.global.shared::cta.bulk_group.add.u32 g, s",
                                                    "cp.async.bulk.commit_group", "cp.async.bulk.wait_group 0",
                                                    "st.release.gpu f, 1"],
              ["ld.acquire.gpu r0, f", "ld.weak.global r1, g"]], "P1:r0 == 1 /\\ P1:r1 == 0", ["s=0 @cta 0"],
             [(0, 0), (1, 0)])
    # multicast into two CTAs, each with its own mbarrier
    mc = "cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes.multicast::cluster"
    mc_init = ["g=5", "d0=0 @cta 0", "d1=0 @cta 1", "b0=mbarrier(1) @cta 0", "b1=mbarrier(1) @cta 1"]
    for wsc in ("cta", "cluster"):
        test("async", f"multicast+reader1.{wsc}", "A multicast bulk copy into CTAs 0 and 1; a thread of CTA 1 "
             f"waits on its own mbarrier (.{wsc}) and reads",
             [["mbarrier.arrive.expect_tx.release.cta b0, 1", f"{mc} d0+d1, g, b0+b1"],
              ["mbarrier.arrive.expect_tx.release.cta b1, 1", f"mbarrier.try_wait.parity.acquire.{wsc} r0, b1, 0",
               "ld.weak.shared::cta r1, d1"]], "P1:r0 == 1 /\\ P1:r1 != 5", mc_init, [(0, 0), (1, 0)])
        test("async", f"multicast+reader0.{wsc}", "A multicast bulk copy into CTAs 0 and 1; the issuing thread "
             f"waits on its CTA's mbarrier (.{wsc}) and reads",
             [["mbarrier.arrive.expect_tx.release.cta b0, 1", f"{mc} d0+d1, g, b0+b1",
               f"mbarrier.try_wait.parity.acquire.{wsc} r0, b0, 0", "ld.weak.shared::cta r1, d0"],
              ["mbarrier.arrive.expect_tx.release.cta b1, 1"]], "P0:r0 == 1 /\\ P0:r1 != 5", mc_init, [(0, 0), (1, 0)])
    test("async", "multicast+no-wait", "A multicast copy read in CTA 1 without a wait",
         [["mbarrier.arrive.expect_tx.release.cta b0, 1", f"{mc} d0+d1, g, b0+b1"], ["ld.weak.shared::cta r1, d1"]],
         "P1:r1 != 5", mc_init, [(0, 0), (1, 0)])
    # st.async and red.async into another CTA's shared memory
    for op, ins, cond in (("st.async", "st.async.shared::cluster.mbarrier::complete_tx::bytes.b32 d, 1, b", "P1:r1 == 0"),
                          ("red.async", "red.async.relaxed.cluster.shared::cluster.mbarrier::complete_tx::bytes.add.u32 d, 1, b",
                           "P1:r1 == 0")):
        for wsc in ("cta", "cluster"):
            test("async", f"MP+{op}.{wsc}", f"{op} into CTA 1's shared memory; a thread there waits on the mbarrier "
                 f"(.{wsc}) and reads", [[ins], ["mbarrier.arrive.expect_tx.release.cta b, 1",
                                                 f"mbarrier.try_wait.parity.acquire.{wsc} r0, b, 0", "ld.weak.shared::cta r1, d"]],
                 f"P1:r0 == 1 /\\ {cond}", ["d=0 @cta 1", "b=mbarrier(1) @cta 1"], [(0, 0), (1, 0)])
        test("async", f"{op}+no-wait", f"{op} read without waiting", [[ins], ["ld.weak.shared::cta r1, d"]],
             "P1:r1 == 1", ["d=0 @cta 1", "b=mbarrier(1) @cta 1"], [(0, 0), (1, 0)])
        test("async", f"MP+{op}+data", f"Data stored before {op} by the same thread, read after the wait",
             [["st.weak.shared::cluster e, 1", ins], ["mbarrier.arrive.expect_tx.release.cta b, 1",
                                                     "mbarrier.try_wait.parity.acquire.cluster r0, b, 0", "ld.weak.shared::cta r1, e"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["d=0 @cta 1", "e=0 @cta 1", "b=mbarrier(1) @cta 1"], [(0, 0), (1, 0)])
        test("async", f"atomicity+{op}", f"{op} and a generic store to the same location",
             [[ins], ["st.weak.shared::cta d, 2", "mbarrier.arrive.expect_tx.release.cta b, 1",
                      "mbarrier.try_wait.parity.acquire.cluster r0, b, 0", "ld.weak.shared::cta r1, d"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["d=0 @cta 1", "b=mbarrier(1) @cta 1"], [(0, 0), (1, 0)])
    # proxy fences between generic writes and async reads, by state space
    for f, tag in (("fence.proxy.async", "all"), ("fence.proxy.async.shared::cta", "shared-cta"),
                   ("fence.proxy.async.shared::cluster", "shared-cluster"), ("fence.proxy.async.global", "global"),
                   (None, "none")):
        test("async", f"generic-to-async+{tag}", "A generic store to shared memory, then a bulk store of it to "
             f"global memory by the same thread; proxy fence: {tag}",
             [["st.weak.shared::cta s, 1"] + ([f] if f else []) + ["cp.async.bulk.global.shared::cta.bulk_group g, s",
                                                                   "cp.async.bulk.commit_group", "cp.async.bulk.wait_group 0",
                                                                   "ld.weak.global r0, g"]],
             "P0:r0 == 0", ["s=0 @cta 0"])
        test("async", f"async-to-generic+{tag}", "A bulk copy into shared memory, its wait, then a generic read by "
             f"the same thread; proxy fence: {tag}",
             [["mbarrier.arrive.expect_tx.release.cta b, 1", f"{tma} d, g, b",
               "mbarrier.try_wait.parity.acquire.cta r0, b, 0"] + ([f] if f else []) + ["ld.weak.shared::cta r1, d"]],
             "P0:r0 == 1 /\\ P0:r1 != 5", ["g=5", "d=0 @cta 0", "b=mbarrier(1) @cta 0"])
        test("async", f"generic-to-async-other-thread+{tag}", "A generic store in one thread, a bulk store of the "
             f"same shared location by another after bar.sync; proxy fence ({tag}) in the writer",
             [["st.weak.shared::cta s, 1"] + ([f] if f else []) + ["bar.sync 0"],
              ["bar.sync 0", "cp.async.bulk.global.shared::cta.bulk_group g, s", "cp.async.bulk.commit_group",
               "cp.async.bulk.wait_group 0", "ld.weak.global r0, g"]], "P1:r0 == 0", ["s=0 @cta 0"])
    # tensor copies (tile, im2col, multicast, store, reduce) through a tensor map
    tens = {"tile": "cp.async.bulk.tensor.1d.shared::cluster.global.tile.mbarrier::complete_tx::bytes d, g, b, tm, r2",
            "im2col": "cp.async.bulk.tensor.3d.shared::cluster.global.im2col.mbarrier::complete_tx::bytes d, g, b, tm, r2",
            "multicast": "cp.async.bulk.tensor.1d.shared::cluster.global.tile.mbarrier::complete_tx::bytes.multicast::cluster d, g, b, tm, r2"}
    for kind, ins in tens.items():
        for scope, where, owner in (("cta", [(0, 0), (0, 0)], 0), ("cluster", [(0, 0), (1, 0)], 1)):
            test("async", f"TMA-tensor-{kind}+reader.{scope}", f"A tensor copy ({kind}) into CTA {owner}'s shared "
                 "memory; a thread there waits and reads", [[ins],
                                                           ["mbarrier.arrive.expect_tx.release.cta b, 1",
                                                            f"mbarrier.try_wait.parity.acquire.{scope} r0, b, 0",
                                                            "ld.weak.shared::cta r1, d"]],
                 "P1:r0 == 1 /\\ P1:r1 != 5", ["g=5", "tm=1", f"d=0 @cta {owner}", f"b=mbarrier(1) @cta {owner}"], where)
            test("async", f"TMA-tensor-{kind}+no-wait.{scope}", f"The tensor copy ({kind}) read without a wait",
                 [[ins], ["ld.weak.shared::cta r1, d"]], "P1:r1 != 5",
                 ["g=5", "tm=1", f"d=0 @cta {owner}", f"b=mbarrier(1) @cta {owner}"], where)
            test("async", f"TMA-tensor-{kind}+map.{scope}", f"The tensor copy ({kind}) reads the tensor map written "
                 "before it by the same thread with tensormap.replace and the proxy fences",
                 [["tensormap.replace.tile.global_address.global.b1024.b64 tm, 2",
                   "fence.proxy.tensormap::generic.release.gpu", "fence.proxy.tensormap::generic.acquire.gpu tm, 128", ins]],
                 "P0:r2 == 1", ["g=5", "tm=1", f"d=0 @cta {owner}", f"b=mbarrier(1) @cta {owner}"], [(owner, 0)])
            test("async", f"TMA-tensor-{kind}+map-no-fence.{scope}", f"The same without the tensormap proxy fences",
                 [["tensormap.replace.tile.global_address.global.b1024.b64 tm, 2", ins]], "P0:r2 == 1",
                 ["g=5", "tm=1", f"d=0 @cta {owner}", f"b=mbarrier(1) @cta {owner}"], [(owner, 0)])
    for f in ("fence.proxy.async.shared::cta", None):
        tag = "+fence" if f else "+no-fence"
        for wait, wtag in (("cp.async.bulk.wait_group 0", "wait"), ("cp.async.bulk.wait_group.read 0", "wait.read"), (None, "no-wait")):
            body = ["st.weak.shared::cta s, 1"] + ([f] if f else []) + [
                "cp.async.bulk.tensor.1d.global.shared::cta.tile.bulk_group g, s, tm, r2", "cp.async.bulk.commit_group"] + \
                ([wait] if wait else [])
            test("async", f"TMA-tensor-store{tag}+{wtag}", "A tensor store of shared memory to global memory, then "
                 "a released flag; another CTA acquires and reads", [body + ["st.release.gpu f, 1"],
                                                                     ["ld.acquire.gpu r0, f", "ld.weak.global r1, g"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", ["s=0 @cta 0", "tm=1"], [(0, 0), (1, 0)])
            test("async", f"TMA-tensor-reduce{tag}+{wtag}", "A tensor reduction (add) of shared memory into global "
                 "memory, then a released flag", [["st.weak.shared::cta s, 1"] + ([f] if f else []) + [
                     "cp.reduce.async.bulk.tensor.1d.global.shared::cta.add.tile.bulk_group g, s, tm, r2",
                     "cp.async.bulk.commit_group"] + ([wait] if wait else []) + ["st.release.gpu f, 1"],
                     ["ld.acquire.gpu r0, f", "ld.weak.global r1, g"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", ["s=0 @cta 0", "tm=1"], [(0, 0), (1, 0)])
    # tensor-map updates across threads: each combination of the two proxy fences
    for rel in (True, False):
        for acq in (True, False):
            for pk, where in (("same-cta", [(0, 0), (0, 0)]), ("same-cluster", [(0, 0), (1, 0)]),
                              ("diff-cluster", [(0, 0), (1, 1)])):
                if pk == "diff-cluster":  # shared memory of a CTA in another cluster: the same-cluster case covers it
                    continue
                test("async", f"MP+tensormap{'+rel' if rel else ''}{'+acq' if acq else ''}+{pk}",
                     f"tensormap.replace, {'a release proxy fence, ' if rel else ''}a released flag; the reader "
                     f"acquires the flag{', an acquire proxy fence' if acq else ''}, then a tensor copy through the map",
                     [["tensormap.replace.tile.global_address.global.b1024.b64 tm, 1"] +
                      (["fence.proxy.tensormap::generic.release.gpu"] if rel else []) + ["st.release.gpu f, 1"],
                      ["ld.acquire.gpu r0, f"] + (["fence.proxy.tensormap::generic.acquire.gpu tm, 128"] if acq else []) +
                      [tens["tile"]]], "P1:r0 == 1 /\\ P1:r2 == 0",
                     ["g=5", "d=0 @cta " + str(where[1][0]), "b=mbarrier(1) @cta " + str(where[1][0])], where)
            test("async", f"cp_fenceproxy{'+acq' if acq else ''}{'+relflag' if rel else '+relaxedflag'}",
                 "tensormap.cp_fenceproxy copies a map from shared memory and releases it to the tensormap proxy; "
                 "the reader takes the flag and copies through the map",
                 [["tensormap.cp_fenceproxy.global.shared::cta.tensormap::generic.release.gpu.sync.aligned tm, tms, 128",
                   f"st.{'release' if rel else 'relaxed'}.gpu f, 1"],
                  [f"ld.{'acquire' if rel else 'relaxed'}.gpu r0, f"] +
                  (["fence.proxy.tensormap::generic.acquire.gpu tm, 128"] if acq else []) + [tens["tile"]]],
                 "P1:r0 == 1 /\\ P1:r2 == 0", ["tms=1 @cta 0", "g=5", "d=0 @cta 1", "b=mbarrier(1) @cta 1"],
                 [(0, 0), (1, 0)])


# -------------------------------------------------------------------------------------------- wgmma, matrix

def gen_wgmma() -> None:
    mma = "wgmma.mma_async.sync.aligned r0, a, c"
    seqs = {
        "fence.proxy.async+wgmma.fence": ["st.weak.shared::cta a, 1", "fence.proxy.async.shared::cta",
                                          "wgmma.fence.sync.aligned", mma],
        "fence.proxy.async": ["st.weak.shared::cta a, 1", "fence.proxy.async.shared::cta", mma],
        "wgmma.fence": ["st.weak.shared::cta a, 1", "wgmma.fence.sync.aligned", mma],
        "no-fence": ["st.weak.shared::cta a, 1", mma],
    }
    for tag, body in seqs.items():
        for wait in ("wait0", "no-wait"):
            tail = ["wgmma.commit_group.sync.aligned"] + (["wgmma.wait_group.sync.aligned 0"] if wait == "wait0" else [])
            test("wgmma", f"RAW+{tag}+{wait}", f"A thread writes the shared operand, then wgmma reads it ({tag}, {wait})",
                 [body + tail], "P0:r0 == 0", ["a=0 @cta 0", "c=0 @cta 0"])
    for tag, pre in (("fence", ["fence.proxy.async.shared::cta"]), ("no-fence", [])):
        test("wgmma", f"RAW-other-thread+{tag}", "Another thread writes the operand, releases a flag; the wgmma "
             "thread acquires it, fences and multiplies",
             [["st.weak.shared::cta a, 1"] + pre + ["st.release.cta.shared::cta f, 1"],
              ["ld.acquire.cta.shared::cta r1, f", "wgmma.fence.sync.aligned", mma, "wgmma.commit_group.sync.aligned",
               "wgmma.wait_group.sync.aligned 0"]], "P1:r1 == 1 /\\ P1:r0 == 0", ["a=0 @cta 0", "c=0 @cta 0", "f=0 @cta 0"])
        test("wgmma", f"RAW-bar+{tag}", "Another thread writes the operand; bar.sync; the wgmma thread multiplies",
             [["st.weak.shared::cta a, 1"] + pre + ["bar.sync 0"],
              ["bar.sync 0", "wgmma.fence.sync.aligned", mma, "wgmma.commit_group.sync.aligned",
               "wgmma.wait_group.sync.aligned 0"]], "P1:r0 == 0", ["a=0 @cta 0", "c=0 @cta 0"])
    for wait in ("wait0", "wait1", "no-wait"):
        tail = {"wait0": ["wgmma.wait_group.sync.aligned 0"], "wait1": ["wgmma.wait_group.sync.aligned 1"], "no-wait": []}[wait]
        test("wgmma", f"WAR+{wait}", "wgmma reads the operand, then the thread overwrites it: can the wgmma see the "
             "new value?", [["wgmma.fence.sync.aligned", mma, "wgmma.commit_group.sync.aligned"] + tail +
                            ["st.weak.shared::cta a, 2"]], "P0:r0 == 2", ["a=1 @cta 0", "c=0 @cta 0"])
        test("wgmma", f"WAR-other-thread+{wait}", "wgmma reads the operand, then bar.sync, and another thread "
             "overwrites it", [["wgmma.fence.sync.aligned", mma, "wgmma.commit_group.sync.aligned"] + tail + ["bar.sync 0"],
                               ["bar.sync 0", "st.weak.shared::cta a, 2"]], "P0:r0 == 2", ["a=1 @cta 0", "c=0 @cta 0"])
    # ldmatrix and stmatrix through shared memory
    stm = "stmatrix.sync.aligned.m8n8.x1.shared.b16 s, 1"
    ldm = "ldmatrix.sync.aligned.m8n8.x1.shared.b16 r0, s"
    for sync, tag in ((["bar.sync 0"], "bar.sync"), (["barrier.sync 1, 2"], "barrier.sync"), ([], "no-sync")):
        test("wgmma", f"MP+stmatrix+ldmatrix+{tag}", f"stmatrix in one thread, ldmatrix in another ({tag})",
             [[stm] + sync, sync + [ldm]], "P1:r0 == 0", ["s=0 @cta 0"])
        test("wgmma", f"MP+st+ldmatrix+{tag}", f"A generic store in one thread, ldmatrix in another ({tag})",
             [["st.weak.shared::cta s, 1"] + sync, sync + [ldm]], "P1:r0 == 0", ["s=0 @cta 0"])
        test("wgmma", f"MP+stmatrix+ld+{tag}", f"stmatrix in one thread, a generic load in another ({tag})",
             [[stm] + sync, sync + ["ld.weak.shared::cta r0, s"]], "P1:r0 == 0", ["s=0 @cta 0"])
    test("wgmma", "CoWR+stmatrix+ldmatrix", "A thread stores with stmatrix and reads back with ldmatrix",
         [[stm, ldm]], "P0:r0 == 0", ["s=0 @cta 0"])
    test("wgmma", "MP+stmatrix+ldmatrix+release-acquire", "stmatrix, a release; ldmatrix after the acquire",
         [[stm, "st.release.cta.shared::cta f, 1"], ["ld.acquire.cta.shared::cta r1, f", ldm]], "P1:r1 == 1 /\\ P1:r0 == 0",
         ["s=0 @cta 0", "f=0 @cta 0"])


# ------------------------------------------------------------------------------------------------- the rest

def gen_misc() -> None:
    # griddepcontrol: grid 1 depends on grid 0
    for trig in ("launch", "no-launch"):
        pre = ["griddepcontrol.launch_dependents"] if trig == "launch" else []
        for wait in ("wait", "no-wait"):
            w = ["griddepcontrol.wait"] if wait == "wait" else []
            test("misc", f"MP+griddep.{trig}.{wait}", f"Grid 0 stores; grid 1 ({wait}) reads ({trig})",
                 [["st.weak.global x, 1"] + pre, w + ["ld.weak.global r0, x"]], "P1:r0 == 0", [],
                 [(0, None, 0, 0), (0, None, 0, 1)])
            test("misc", f"WAR+griddep.{trig}.{wait}", f"Grid 0 reads late; grid 1 ({wait}) writes ({trig})",
                 [pre + ["ld.weak.global r0, x"], w + ["st.weak.global x, 1"]], "P0:r0 == 1", [],
                 [(0, None, 0, 0), (0, None, 0, 1)])
        test("misc", f"MP+griddep.{trig}.chain", "Three grids, each waiting for the one before",
             [["st.weak.global x, 1"] + pre, ["griddepcontrol.wait"] + pre, ["griddepcontrol.wait", "ld.weak.global r0, x"]],
             "P2:r0 == 0", [], [(0, None, 0, 0), (0, None, 0, 1), (0, None, 0, 2)])
    # multimem (several GPUs; models only)
    for v in ("weak", "relaxed", "release"):
        stq = "multimem.st.global.u32 m, 1" if v == "weak" else f"multimem.st.{v}.sys.global.u32 m, 1"
        test("misc", f"MP+multimem.st.{v}", f"multimem.st ({v}) of the flag to two GPUs' copies; a reader on GPU 1",
             [["st.weak.global d, 1", stq], ["ld.acquire.sys.global r0, y", "ld.weak.global r1, d"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["x=0", "y=0", "m=multimem(x, y)"], [(0, None, 0), (0, None, 1)])
        test("misc", f"value+multimem.st.{v}", f"multimem.st ({v}) writes every copy",
             [[stq]], "x != 1 \\/ y != 1", ["x=0", "y=0", "m=multimem(x, y)"], [(0, None, 0)])
    test("misc", "multimem.red+final", "Two multimem.red on the same copies: no lost update",
         [["multimem.red.relaxed.sys.global.add.u32 m, 1"], ["multimem.red.relaxed.sys.global.add.u32 m, 1"]],
         "x == 1", ["x=0", "y=0", "m=multimem(x, y)"], [(0, None, 0), (0, None, 1)])
    test("misc", "multimem.ld_reduce+values", "multimem.ld_reduce adds the copies",
         [["st.relaxed.sys.global y, 2", "multimem.ld_reduce.relaxed.sys.global.add.u32 r0, m"]], "P0:r0 == 0",
         ["x=1", "y=0", "m=multimem(x, y)"], [(0, None, 0)])
    # discard: the line's content becomes unspecified, never other memory
    for pk, where in PLACES.items():
        test("misc", f"CoWR+discard+{pk}", "A store, discard of its line, a read: the read may return any value",
             [["st.weak.global x, 1", "discard.global.L2 x, 128", "ld.weak.global r0, x"], ["st.weak.global y, 1"]],
             "P0:r0 == 7", [], where)
        test("misc", f"discard+other-location+{pk}", "discard of one line leaves other locations alone",
             [["st.weak.global y, 1", "discard.global.L2 x, 128", "ld.weak.global r0, y"], ["st.weak.global z, 1"]],
             "P0:r0 != 1", [], where)
        test("misc", f"MP+discard+{pk}", "Message passing where the reader discards an unrelated line",
             [["st.weak.global x, 1", "st.release.gpu f, 1"],
              ["ld.acquire.gpu r0, f", "discard.global.L2 z, 128", "ld.weak.global r1, x"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", [], where)
    # prefetches and cache policies change nothing
    hints = {"prefetch.L1": "prefetch.global.L1 x", "prefetch.L2": "prefetch.global.L2 x",
             "prefetch.L2-evict_last": "prefetch.global.L2::evict_last x", "prefetchu": "prefetchu.L1 x",
             "applypriority": "applypriority.global.L2::evict_normal x",
             "createpolicy": "createpolicy.fractional.L2::evict_last.b64 r9, 1.0",
             "bulk-prefetch": "cp.async.bulk.prefetch.L2.global x",
             "bulk-prefetch-tensor": "cp.async.bulk.prefetch.tensor.1d.L2.global.tile tm",
             "prefetch-tensormap": "prefetch.tensormap tm"}
    for tag, h in hints.items():
        for v, (fw, fr) in {"relaxed": ("relaxed", "relaxed"), "rel-acq": ("release", "acquire")}.items():
            for pk in ("same-cluster", "diff-cluster"):
                test("misc", f"MP+{tag}+{v}+{pk}", f"Message passing where the reader issues {h.split()[0]} first; flag "
                     f"{fw}/{fr}", [["st.weak.global x, 1", f"st.{fw}.gpu f, 1"], [h, f"ld.{fr}.gpu r0, f", "ld.weak.global r1, x"]],
                     "P1:r0 == 1 /\\ P1:r1 == 0", ["tm=1"] if "tm" in h else [], PLACES[pk])
        test("misc", f"CoWR+{tag}", f"{h.split()[0]} between a store and a read of the same location",
             [["st.weak.global x, 1", h, "ld.weak.global r0, x"]], "P0:r0 == 0", ["tm=1"] if "tm" in h else [])
        test("misc", f"value+{tag}", f"{h.split()[0]} does not change the value read",
             [[h, "ld.weak.global r0, x"]], "P0:r0 != 0", ["tm=1"] if "tm" in h else [])


def gen_more() -> None:
    """The cases the other generators leave short of the bar of tools/litmus/scorecard.py."""
    shared_lks = ["shared-cta", "dsmem-local", "dsmem-remote-reader", "dsmem-remote-writer"]
    for lk in shared_lks:
        where, _, ws, rs, what = LOCS[lk]
        test("rmw", f"MP+atom-acquire.cluster+{lk}", f"Message passing in {what}, the flag read by atom.acquire.cluster",
             [[st("weak", "", ws, "x", 1), st("release", "cluster", ws, "f", 1)],
              [f"atom.acquire.cluster{rs}.add r0, f, 0", ld("weak", "", rs, "r1", "x")]],
             "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x", "f"), where)
        test("rmw", f"MP+atom-acq_rel.cluster+{lk}", f"Message passing in {what} with atom.acq_rel.cluster on both sides",
             [[st("weak", "", ws, "x", 1), f"atom.acq_rel.cluster{ws}.exch r9, f, 1"],
              [f"atom.acq_rel.cluster{rs}.add r0, f, 0", ld("weak", "", rs, "r1", "x")]],
             "P1:r0 == 1 /\\ P1:r1 == 0", decls(lk, "x", "f"), where)
        test("rmw", f"LU+cas.b128.cluster+{lk}", f"Two .cluster 128-bit compare-and-swaps on a location in {what}",
             [[f"atom.relaxed.cluster{ws}.cas.b128 r0, x, 0, 1"], [f"atom.relaxed.cluster{rs}.cas.b128 r1, x, 0, 2"]],
             "P0:r0 == 0 /\\ P1:r1 == 0", decls(lk, "x"), where)
        test("rmw", f"LU+add.f16.cluster+{lk}", f"Two .cluster half-precision atom.add on a location in {what}",
             [[f"atom.relaxed.cluster{ws}.add.noftz.f16 r0, x, 1"], [f"atom.relaxed.cluster{rs}.add.noftz.f16 r1, x, 1"]],
             "P0:r0 == 0 /\\ P1:r1 == 0", decls(lk, "x"), where)
    # generic addresses of the own CTA's shared memory (no state space qualifier)
    for s in SCOPES:
        test("ldst", f"MP+rel-acq.{s}+generic-shared", f"Message passing through the CTA's shared memory with generic "
             f"addresses; flag release/acquire at .{s}",
             [["st.weak x, 1", f"st.release.{s} f, 1"], [f"ld.acquire.{s} r0, f", "ld.weak r1, x"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["x=0 @cta 0", "f=0 @cta 0"])
        test("ldst", f"CoRR+relaxed.{s}+generic-shared", "Two relaxed reads of a shared location through generic "
             f"addresses, at .{s}", [[f"st.relaxed.{s} x, 1"], [f"ld.relaxed.{s} r0, x", f"ld.relaxed.{s} r1, x"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["x=0 @cta 0"])
    # prefetches and policies with both threads in one CTA
    hints = {"prefetch.L2": "prefetch.global.L2 x", "prefetchu": "prefetchu.L1 x",
             "applypriority": "applypriority.global.L2::evict_normal x",
             "createpolicy": "createpolicy.fractional.L2::evict_last.b64 r9, 1.0",
             "bulk-prefetch": "cp.async.bulk.prefetch.L2.global x",
             "bulk-prefetch-tensor": "cp.async.bulk.prefetch.tensor.1d.L2.global.tile tm",
             "prefetch-tensormap": "prefetch.tensormap tm"}
    for tag, h in hints.items():
        for v, (fw, fr) in {"relaxed": ("relaxed", "relaxed"), "rel-acq": ("release", "acquire")}.items():
            test("misc", f"MP+{tag}+{v}+same-cta", f"Message passing in one CTA where the reader issues {h.split()[0]} "
                 f"first; flag {fw}/{fr}", [["st.weak.global x, 1", f"st.{fw}.gpu f, 1"],
                                           [h, f"ld.{fr}.gpu r0, f", "ld.weak.global r1, x"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", ["tm=1"] if "tm" in h else [], [(0, 0), (0, 0)])
    # cp.async groups
    q = "cp.async.ca.shared.global"
    for w in (0, 1):
        test("async", f"cp.async.two-groups+wait_group{w}", f"Two committed groups of cp.async; wait_group {w}: is the "
             "first copy complete?", [["st.weak.global g, 1", "st.weak.global h, 1", f"{q} d, g", "cp.async.commit_group",
                                       f"{q} e, h", "cp.async.commit_group", f"cp.async.wait_group {w}",
                                       "ld.weak.shared r0, d", "ld.weak.shared r1, e"]],
             "P0:r0 == 0 \\/ P0:r1 == 0", ["d=0 @cta 0", "e=0 @cta 0"])
    # bulk reductions
    red = "cp.reduce.async.bulk.global.shared::cta.bulk_group.add.u32 g, s"
    test("async", "MP+reduce+wait.read", "A bulk reduction waited for with wait_group.read, then a released flag",
         [["st.weak.shared::cta s, 1", "fence.proxy.async.shared::cta", red, "cp.async.bulk.commit_group",
           "cp.async.bulk.wait_group.read 0", "st.release.gpu f, 1"], ["ld.acquire.gpu r0, f", "ld.weak.global r1, g"]],
         "P1:r0 == 1 /\\ P1:r1 == 0", ["s=0 @cta 0"], [(0, 0), (1, 0)])
    tred = "cp.reduce.async.bulk.tensor.1d.global.shared::cta.add.tile.bulk_group g, s, tm, r2"
    for f in ("fence.proxy.async.shared::cta", None):
        test("async", f"tensor-reduce+atomic{'+fence' if f else '+no-fence'}", "A tensor reduction and a generic "
             "red.add on the same global location: no lost update",
             [["st.weak.shared::cta s, 1"] + ([f] if f else []) + [tred, "cp.async.bulk.commit_group",
                                                                   "cp.async.bulk.wait_group 0"],
              ["red.relaxed.gpu.global.add g, 1"]], "g == 1", ["s=0 @cta 0", "tm=1"], [(0, 0), (1, 0)])
    # fence.mbarrier_init with try_wait
    for scope, where, sp in (("cta", [(0, 0), (0, 0)], ""), ("cluster", [(0, 0), (1, 0)], ".shared::cluster")):
        sync = ["bar.sync 0"] if scope == "cta" else ["barrier.cluster.arrive.relaxed", "barrier.cluster.wait"]
        sync2 = ["bar.sync 0"] if scope == "cta" else ["barrier.cluster.arrive", "barrier.cluster.wait"]
        test("mbarrier", f"init+fence+use+try_wait.{scope}", "mbarrier.init, fence.mbarrier_init, then an arrive from "
             "another thread; the owner waits with try_wait",
             [["mbarrier.init.shared::cta b, 1", "fence.mbarrier_init.release.cluster"] + sync + sync2 +
              ["mbarrier.try_wait.parity.acquire.cta r0, b, 0"], sync + [f"mbarrier.arrive.release.{scope}{sp} b"] + sync2],
             "P0:r0 == 0", ["b=mbarrier() @cta 0"], where)
        # mbarrier.inval after a completed phase, then a new init
        test("mbarrier", f"inval+reinit+wait.{scope}", "A phase completes, the object is invalidated and initialized "
             "again; the new phase is the first one",
             [["mbarrier.arrive.release.cta b", "mbarrier.test_wait.parity.acquire.cta r0, b, 0",
               "mbarrier.inval.shared::cta b", "mbarrier.init.shared::cta b, 1",
               "mbarrier.test_wait.parity.acquire.cta r1, b, 0"]], "P0:r0 == 1 /\\ P0:r1 == 1", ["b=mbarrier(1) @cta 0"],
             [(0, 0)])
    test("mbarrier", "inval+after-barrier", "One thread uses the object, a barrier, then another invalidates it",
         [["mbarrier.arrive.release.cta r0, b", "bar.sync 0"], ["bar.sync 0", "mbarrier.inval.shared::cta b"]],
         "P0:r0 != 0", ["b=mbarrier(1) @cta 0"])
    # red.async: two reductions into one location, and a count of two transactions
    rasync = "red.async.relaxed.cluster.shared::cluster.mbarrier::complete_tx::bytes.add.u32 d, 1, b"
    test("async", "LU+red.async", "Two red.async from two CTAs into a third CTA's location: no lost update",
         [[rasync], [rasync], ["mbarrier.arrive.expect_tx.release.cta b, 2", "mbarrier.try_wait.parity.acquire.cluster r0, b, 0",
                               "ld.weak.shared::cta r1, d"]], "P2:r0 == 1 /\\ P2:r1 != 2",
         ["d=0 @cta 2", "b=mbarrier(1) @cta 2"], [(0, 0), (1, 0), (2, 0)])
    test("async", "red.async+expect_tx2", "The phase needs two red.async transactions; after one, it is still open",
         [[rasync], ["mbarrier.arrive.expect_tx.release.cta b, 2", "mbarrier.test_wait.parity.acquire.cluster r0, b, 0"]],
         "P1:r0 == 1", ["d=0 @cta 1", "b=mbarrier(1) @cta 1"], [(0, 0), (1, 0)])
    # a bulk copy from shared::cta into the own CTA through the cluster window
    s2c = "cp.async.bulk.shared::cluster.shared::cta.mbarrier::complete_tx::bytes d, s, b"
    for f in ("fence.proxy.async.shared::cta", None):
        for wait in (True, False):
            test("async", f"self-copy{'+fence' if f else '+no-fence'}{'+wait' if wait else '+no-wait'}",
                 "A bulk copy from shared memory into another location of the same CTA's shared memory",
                 [["st.weak.shared::cta s, 5"] + ([f] if f else []) + ["mbarrier.arrive.expect_tx.release.cta b, 1", s2c] +
                  (["mbarrier.try_wait.parity.acquire.cta r0, b, 0"] if wait else []) + ["ld.weak.shared::cta r1, d"]],
                 ("P0:r0 == 1 /\\ " if wait else "") + "P0:r1 != 5", ["s=0 @cta 0", "d=0 @cta 0", "b=mbarrier(1) @cta 0"])
    # restricted fences within one CTA
    for loc in ("shared", "global"):
        q = ".shared::cta" if loc == "shared" else ".global"
        init = ["s=0 @cta 0"] if loc == "shared" else []
        test("ldst", f"MP+fence-restrict+same-cta+{loc}", "Message passing in one CTA with the restricted release "
             "and acquire fences", [[f"st.weak{q} s, 1", "fence.release.sync_restrict::shared::cta.cluster",
                                     "st.relaxed.cluster f, 1"],
                                    ["ld.relaxed.cluster r0, f", "fence.acquire.sync_restrict::shared::cluster.cluster",
                                     f"ld.weak{q} r1, s"]], "P1:r0 == 1 /\\ P1:r1 == 0", init)
    test("ldst", "MP+fence-restrict-release+same-cta", "Message passing in one CTA with a restricted release fence "
         "and an acquire load", [["st.weak.shared::cta s, 1", "fence.release.sync_restrict::shared::cta.cluster",
                                  "st.relaxed.cluster f, 1"], ["ld.acquire.cluster r0, f", "ld.weak.shared::cta r1, s"]],
         "P1:r0 == 1 /\\ P1:r1 == 0", ["s=0 @cta 0"])
    # arrive on the own CTA's mbarrier through the cluster window
    for asem in ("release", "relaxed"):
        test("mbarrier", f"MP+mbarrier.{asem}.cluster-window+same-cta", "An arrive on the own CTA's mbarrier through "
             f"its shared::cluster address (.{asem}.cluster)",
             [["st.weak x, 1", f"mbarrier.arrive.{asem}.cluster.shared::cluster b"],
              ["mbarrier.test_wait.parity.acquire.cluster r0, b, 0", "ld.weak r1, x"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["b=mbarrier(1) @cta 0"])
    # tensormap proxy fences at every scope
    tile = "cp.async.bulk.tensor.1d.shared::cluster.global.tile.mbarrier::complete_tx::bytes d, g, b, tm, r2"
    for s in SCOPES:
        for pk, where in (("same-cta", [(0, 0), (0, 0)]), ("same-cluster", [(0, 0), (1, 0)]),
                          ("diff-cluster", [(0, 0), (1, 1)])):
            if s == "gpu" and pk != "diff-cluster":
                continue  # in gen_async
            test("async", f"MP+tensormap+rel+acq.{s}+{pk}", f"tensormap.replace, the release proxy fence and a "
                 f"released flag at .{s}; the reader acquires both and copies through the map",
                 [["tensormap.replace.tile.global_address.global.b1024.b64 tm, 1",
                   f"fence.proxy.tensormap::generic.release.{s}", f"st.release.{s} f, 1"],
                  [f"ld.acquire.{s} r0, f", f"fence.proxy.tensormap::generic.acquire.{s} tm, 128", tile]],
                 "P1:r0 == 1 /\\ P1:r2 == 0", ["g=5", f"d=0 @cta {where[1][0]}", f"b=mbarrier(1) @cta {where[1][0]}"],
                 where)


def gen_mutation_gaps() -> None:
    """Tests for the rules no other test exercised (survivors of tools/litmus/mutate.py)."""
    # the wait of a CTA barrier acts as an acq_rel fence (D10): a relaxed flag after it passes on the writes of the
    # threads that arrived before; a relaxed flag after a plain fence-less wait elsewhere does not
    # (the barrier counts two threads, so the third thread need not arrive)
    for sync, tag in ((["bar.sync 0, 2"], "bar.sync"), (["barrier.sync 0, 2"], "barrier.sync")):
        for fs, fr in (("relaxed", "acquire"), ("relaxed", "relaxed"), ("release", "acquire")):
            test("bar", f"WRC+{tag}+{fs}-{fr}", f"P0 writes x, meets P1 at {tag}; P1 then sets a {fs} flag that P2 "
                 f"(same CTA) reads {fr}: does P2 see x?",
                 [["st.weak x, 1"] + sync, sync + [f"st.{fs}.cta f, 1"], [f"ld.{fr}.cta r0, f", "ld.weak r1, x"]],
                 "P2:r0 == 1 /\\ P2:r1 == 0", [], [(0, 0), (0, 0), (0, 0)])
        test("bar", f"WRC+{tag}+reader-side", f"P0 sets a released flag; P1 reads it relaxed, then meets P2 at "
             f"{tag} (all in one CTA); does P2, after the barrier, see the data P0 released?",
             [["st.weak x, 1", "st.release.cta f, 1"], ["ld.relaxed.cta r0, f"] + sync, sync + ["ld.weak r1, x"]],
             "P1:r0 == 1 /\\ P2:r1 == 0", [], [(0, 0), (0, 0), (0, 0)])
    # one-sided fences on the wrong side give no ordering (M2, D5)
    for s in ("cta", "gpu"):
        for wf, rf in (("acquire", "release"), ("acquire", "acquire"), ("release", "release")):
            test("fence", f"MP+fence.{wf}-{rf}.{s}", f"Message passing with fence.{wf} before the flag store and "
                 f"fence.{rf} after the flag load (.{s})",
                 [["st.weak x, 1", f"fence.{wf}.{s}", f"st.relaxed.{s} f, 1"],
                  [f"ld.relaxed.{s} r0, f", f"fence.{rf}.{s}", "ld.weak r1, x"]],
                 "P1:r0 == 1 /\\ P1:r1 == 0", [], [(0, 0), (1, 0)])
    # partially overlapping strong accesses: a mixed-size race frees the program from the axioms (D38)
    for s in ("cta", "gpu"):
        test("ldst", f"CoRR+mixed-size.{s}", f"A relaxed 32-bit store and two relaxed 16-bit loads of its low half "
             f"(.{s}): can the second load miss what the first saw?",
             [[f"st.relaxed.{s}.b32 x, 1"], [f"ld.relaxed.{s}.b16 r0, x[0]", f"ld.relaxed.{s}.b16 r1, x[0]"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["x[0]=0", "x[1]=0"], [(0, 0), (1, 0)])
        test("ldst", f"CoRR+same-size.{s}", f"The same with 16-bit stores and loads of one granule (.{s})",
             [[f"st.relaxed.{s}.b16 x[0], 1"], [f"ld.relaxed.{s}.b16 r0, x[0]", f"ld.relaxed.{s}.b16 r1, x[0]"]],
             "P1:r0 == 1 /\\ P1:r1 == 0", ["x[0]=0", "x[1]=0"], [(0, 0), (1, 0)])
    # the uni-directional generic -> async proxy fence of shared memory (fence.proxy.async::generic)
    for sem, restrict in (("release", "sync_restrict::shared::cta"), ("acquire", "sync_restrict::shared::cluster")):
        f = f"fence.proxy.async::generic.{sem}.{restrict}.cluster"
        test("async", f"generic-to-async+{sem}-restrict", f"A generic store to shared memory, {f}, then a bulk store "
             "of it to global memory by the same thread",
             [["st.weak.shared::cta s, 1", f, "cp.async.bulk.global.shared::cta.bulk_group g, s",
               "cp.async.bulk.commit_group", "cp.async.bulk.wait_group 0", "ld.weak.global r0, g"]],
             "P0:r0 == 0", ["s=0 @cta 0"])
    test("async", "generic-to-async+release-restrict+other-thread", "A generic store and the release proxy fence in "
         "one thread, bar.sync, then a bulk store of the location by another thread",
         [["st.weak.shared::cta s, 1", "fence.proxy.async::generic.release.sync_restrict::shared::cta.cluster", "bar.sync 0"],
          ["bar.sync 0", "cp.async.bulk.global.shared::cta.bulk_group g, s", "cp.async.bulk.commit_group",
           "cp.async.bulk.wait_group 0", "ld.weak.global r0, g"]], "P1:r0 == 0", ["s=0 @cta 0"])
    # a wgmma is ordered only after what precedes its latest wgmma.fence (D24): an acquire after the fence does not
    # order the operand read
    test("wgmma", "RAW-other-thread+acquire-after-wgmma.fence", "Another thread writes the operand and releases a "
         "flag; the wgmma thread issues wgmma.fence, then acquires the flag and multiplies",
         [["st.weak.shared::cta a, 1", "fence.proxy.async.shared::cta", "st.release.cta.shared::cta f, 1"],
          ["wgmma.fence.sync.aligned", "ld.acquire.cta.shared::cta r1, f", "wgmma.mma_async.sync.aligned r0, a, c",
           "wgmma.commit_group.sync.aligned", "wgmma.wait_group.sync.aligned 0"]],
         "P1:r1 == 1 /\\ P1:r0 == 0", ["a=0 @cta 0", "c=0 @cta 0", "f=0 @cta 0"])
    # morally strong writes to several granules are ordered the same way on every granule (M15, D6): a read cannot
    # take the newest value of each granule from two different writes
    for s, where in (("cta", [(0, 0)] * 3), ("gpu", [(0, 0), (1, 0), (2, 0)])):
        for sem in ("relaxed", "weak"):
            st = f"st.relaxed.{s}" if sem == "relaxed" else "st.weak"
            test("ldst", f"2W+tear+{sem}.{s}", f"Two {sem} 32-bit stores of two 16-bit granules and a relaxed 32-bit "
                 f"load (.{s}): can the load see one store in one granule and the other store in the other?",
                 [[f"{st}.b32 x, 1"], [f"{st}.b32 x, 2"], [f"ld.relaxed.{s}.b32 r0, x"]],
                 "P2:r0[0] == 1 /\\ P2:r0[1] == 2", ["x[0]=0", "x[1]=0", "P2:r0[0]=0", "P2:r0[1]=0"], where)


GENERATORS = [gen_ldst, gen_rmw, gen_fence, gen_bar, gen_mbarrier, gen_async, gen_wgmma, gen_misc, gen_more,
              gen_mutation_gaps]


def generate() -> dict[Path, str]:
    FILES.clear()
    for g in GENERATORS:
        g()
    return dict(FILES)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    files = generate()
    if a.check:
        bad = [p for p, s in files.items() if not p.exists() or p.read_text() != s]
        extra = sorted(set(OUT.rglob("*.litmus")) - set(files))
        for p in bad + extra:
            print(f"differs or orphaned: {p.relative_to(ROOT)}")
        print(f"{len(files)} tests, {len(bad)} differ, {len(extra)} orphaned")
        return 1 if bad or extra else 0
    for p in set(OUT.rglob("*.litmus")) - set(files):
        p.unlink()
    for p, s in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(s)
    print(f"wrote {len(files)} tests")
    return 0


if __name__ == "__main__":
    sys.exit(main())

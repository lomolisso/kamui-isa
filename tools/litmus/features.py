#!/usr/bin/env python3
"""Which litmus tests exercise which PTX feature of models/ptx87/coverage.yaml.

Each feature gets a rule over the instructions of a test (`litmus.Instr`: mnemonic, qualifiers, operands) and the
test's locations (state space, owner CTA, aliases). The rule answers "does this test use the feature"; the
dimensions it is used in (scopes, state spaces, placements) come from the matching instructions.

    python tools/litmus/features.py                 # tests per feature, one line each
    python tools/litmus/features.py atom.scope.sys  # the tests that use one feature

Register-only features (cvt, mov, shfl, vote, ...) have no memory operation and no litmus form: they are listed
as exempt with that reason.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import litmus  # noqa: E402

ROOT = HERE.parent.parent
COVERAGE = ROOT / "models" / "ptx87" / "coverage.yaml"
SUITE = ROOT / "tests" / "litmus"

SCOPES = ("cta", "cluster", "gpu", "sys")
SPACE_QUALS = {"global": "global", "shared": "shared::cta", "shared::cta": "shared::cta",
               "shared::cluster": "shared::cluster", "local": "local", "const": "const", "param": "param"}
MEM_SPACES = ("global", "shared::cta", "shared::cluster-local", "shared::cluster-remote")
REGISTER_ONLY = ("activemask", "cvt", "cvt.bf16", "cvt.fp", "cvt.fp8", "cvt.half", "cvt.int", "cvt.pack",
                 "cvt.tf32", "cvta", "cvta.shared::cluster", "dir.ptr", "elect.sync", "getctarank", "isspacep",
                 "isspacep.shared::cluster", "mapa", "match.all.sync", "match.any.sync", "mov", "mov.packing",
                 "prmt", "redux.sync", "shfl.sync.bfly", "shfl.sync.down", "shfl.sync.idx", "shfl.sync.up",
                 "space.reg", "space.sreg", "vote.sync.all", "vote.sync.any", "vote.sync.ballot", "vote.sync.uni")
WGMMA_TYPES = ("wgmma.mma_async.b1", "wgmma.mma_async.fp8", "wgmma.mma_async.int8", "wgmma.mma_async.rs",
               "wgmma.mma_async.sp", "wgmma.mma_async.tf32")


# ------------------------------------------------------------------------------------------------ test facts

@dataclass
class Access:
    """One instruction of one thread, with what the rules need."""
    ins: litmus.Instr
    thread: litmus.Thread
    quals: set
    space: str | None  # a MEM_SPACES value for an access to memory, else None
    scope: str | None


@dataclass
class TestFacts:
    tid: str
    test: litmus.Litmus
    accesses: list[Access] = field(default_factory=list)
    placement: str = ""
    aliases: bool = False


def placement_of(t: litmus.Litmus) -> str:
    ctas = {(th.gpu, th.cluster, th.cta) for th in t.threads}
    if len({th.gpu for th in t.threads}) > 1:
        return "multi-gpu"
    if len(ctas) == 1:
        return "same-cta"
    clusters = {(th.gpu, th.cluster) for th in t.threads}
    if len(clusters) == 1 and None not in {th.cluster for th in t.threads}:
        return "same-cluster"
    return "diff-cluster"


def _owners(t: litmus.Litmus) -> tuple[dict, set, set]:
    """Location -> owner CTA for shared locations; the set of shared locations; locations with aliases."""
    owner, shared, aliased = {}, set(), set()
    for d in t.init:
        m = re.match(r"\s*([A-Za-z_]\w*)(?:\[\d+\])?\s*=.*@cta\s+(\d+)", d)
        if m:
            owner[m.group(1)] = int(m.group(2))
            shared.add(m.group(1))
        m = re.match(r"\s*([A-Za-z_]\w*)\s*@\s*\w+\s+aliases\s+([A-Za-z_]\w*)", d)
        if m:
            aliased.update(m.groups())
        if re.search(r"=\s*mbarrier\(", d):
            shared.add(d.split("=")[0].strip())
    for th in t.threads:
        for ins in th.instrs:
            if any(q.startswith("shared") for q in ins.quals):
                for a in ins.args:
                    loc = re.sub(r"\[\d+\]$", "", a.strip())
                    if re.fullmatch(r"[A-Za-z_]\w*", loc) and not re.fullmatch(r"r\d+", loc):
                        shared.add(loc)
                        owner.setdefault(loc, th.cta)
    return owner, shared, aliased


def _space(ins: litmus.Instr, th: litmus.Thread, owner: dict, shared: set) -> str | None:
    qs = [SPACE_QUALS[q] for q in ins.quals if q in SPACE_QUALS]
    locs = [re.sub(r"\[\d+\]$", "", a.strip()) for a in ins.args]
    locs = [x for x in locs if re.fullmatch(r"[A-Za-z_]\w*", x) and not re.fullmatch(r"r\d+", x)]
    if qs and qs[0] in ("local", "const", "param"):
        return qs[0]
    sh = [x for x in locs if x in shared]
    if (qs and qs[0].startswith("shared")) or sh:
        loc = sh[0] if sh else (locs[0] if locs else None)
        q = qs[0] if qs else "shared::cta"
        if q == "shared::cluster":
            return "shared::cluster-remote" if owner.get(loc, th.cta) != th.cta else "shared::cluster-local"
        return "shared::cta"
    if qs and qs[0] == "global" or locs:
        return "global"
    return None


@lru_cache(maxsize=None)
def facts(tid: str) -> TestFacts:
    t = litmus.load(SUITE / f"{tid}.litmus")
    owner, shared, aliased = _owners(t)
    f = TestFacts(tid, t, placement=placement_of(t), aliases=bool(aliased))
    for th in t.threads:
        for ins in th.instrs:
            if ins.is_empty or not ins.op:
                continue
            q = set(ins.quals)
            scope = next((s for s in SCOPES if s in q), None)
            f.accesses.append(Access(ins, th, q, _space(ins, th, owner, shared), scope))
    return f


def all_tests() -> list[str]:
    return sorted(p.relative_to(SUITE).with_suffix("").as_posix() for p in (SUITE / "ptx").rglob("*.litmus"))


# ----------------------------------------------------------------------------------------------- the rules

def op(a: Access, name: str, *need: str, no: tuple = ()) -> bool:
    return a.ins.op == name and all(n in a.quals for n in need) and not (a.quals & set(no))


SEMS = {"weak", "relaxed", "acquire", "release", "acq_rel", "sc", "volatile", "mmio"}
ATOM_OPS = ("add", "and", "or", "xor", "min", "max", "inc", "dec", "exch", "cas")


def rule(fid: str):
    """The predicate Access -> bool of a feature, or None if the feature has no litmus form."""
    head, _, rest = fid.partition(".")
    parts = fid.split(".")
    if fid in REGISTER_ONLY:
        return None
    if fid in WGMMA_TYPES:  # the dialect writes every type variant the same way (memory behaviour of D24)
        return lambda a: op(a, "wgmma", "mma_async")
    if head in ("atom", "red") and rest != "async":
        def r(a, head=head, parts=parts):
            if a.ins.op != head or "async" in a.quals:
                return False
            k, v = (parts[1], parts[2] if len(parts) > 2 else None) if len(parts) > 1 else (None, None)
            if k == "scope":
                return v in a.quals or (v == "gpu" and not (a.quals & set(SCOPES)))
            if k == "sem":
                return v in a.quals or (v == "relaxed" and not (a.quals & SEMS))
            if k in ("global", "generic", "shared", "shared::cluster"):
                opq = v
                if opq and opq not in a.quals:
                    return False
                if k == "generic":
                    return not (a.quals & set(SPACE_QUALS))
                if k == "global":
                    return a.space == "global"
                if k == "shared":
                    return a.space == "shared::cta"
                return a.space and a.space.startswith("shared::cluster")
            if k == "b128":
                return "b128" in a.quals
            if k == "half":
                return bool(a.quals & {"f16", "bf16", "f16x2", "bf16x2"})
            if k == "vector":
                return bool(a.quals & {"v2", "v4", "v8"})
            if k == "scope.cluster" or fid == "red.scope.cluster":
                return "cluster" in a.quals
            return True
        if fid == "red.scope":
            return lambda a: op(a, "red", no=("async",)) and bool(a.quals & {"cta", "gpu", "sys"})
        if fid == "red.scope.cluster":
            return lambda a: op(a, "red", "cluster", no=("async",))
        return r
    if head in ("ld", "st") and parts[1:2] != ["async"]:
        def r(a, head=head, parts=parts):
            if a.ins.op != head:
                return False
            k = parts[1] if len(parts) > 1 else None
            v = parts[2] if len(parts) > 2 else None
            if k == "scope":
                return v in a.quals
            if k == "sem":
                return v in a.quals
            if k == "volatile" or k == "mmio":
                return k in a.quals
            if k == "generic":
                return not (a.quals & set(SPACE_QUALS))
            if k == "global" and v == "nc":
                return "nc" in a.quals
            if k == "global":
                return a.space == "global"
            if k == "shared":
                return a.space == "shared::cta"
            if k == "shared::cluster":
                return a.space is not None and a.space.startswith("shared::cluster")
            if k in ("local", "const", "param"):
                return a.space == k
            if k == "cache_hint":
                return any(q.startswith("L2::") or q.startswith("L1::") for q in a.quals)
            if k == "cache_op":
                return bool(a.quals & {"ca", "cg", "cs", "lu", "cv", "wb", "wt"})
            return True
        return r
    simple = {
        "applypriority": lambda a: a.ins.op == "applypriority",
        "createpolicy": lambda a: a.ins.op == "createpolicy",
        "prefetch": lambda a: a.ins.op == "prefetch" and "tensormap" not in a.quals,
        "prefetchu": lambda a: a.ins.op == "prefetchu",
        "prefetch.tensormap": lambda a: a.ins.op == "prefetch" and "tensormap" in a.quals,
        "discard": lambda a: a.ins.op == "discard",
        "ldu": lambda a: a.ins.op == "ldu",
        "ldmatrix": lambda a: a.ins.op == "ldmatrix",
        "stmatrix": lambda a: a.ins.op == "stmatrix",
        "membar": lambda a: a.ins.op == "membar",
        "multimem": lambda a: a.ins.op == "multimem",
        "griddepcontrol": lambda a: a.ins.op == "griddepcontrol",
        "st.async": lambda a: op(a, "st", "async"),
        "red.async": lambda a: op(a, "red", "async"),
        "bar.arrive": lambda a: a.ins.op in ("bar", "barrier") and "arrive" in a.quals and "cluster" not in a.quals,
        "bar.red": lambda a: a.ins.op in ("bar", "barrier") and "red" in a.quals,
        "bar.sync": lambda a: a.ins.op == "bar" and "sync" in a.quals and "warp" not in a.quals,
        "bar.sync.named": lambda a: a.ins.op in ("bar", "barrier") and "sync" in a.quals and "warp" not in a.quals
        and bool(a.ins.args) and a.ins.args[0].strip() not in ("0",),
        "bar.warp.sync": lambda a: op(a, "bar", "warp", "sync"),
        "barrier.cluster": lambda a: op(a, "barrier", "cluster"),
        "barrier.sync": lambda a: op(a, "barrier", "sync", no=("cluster",)),
        "cp.async": lambda a: op(a, "cp", "async", no=("bulk", "commit_group", "wait_group", "wait_all",
                                                    "mbarrier")) and a.ins.op == "cp",
        "cp.async.commit_group": lambda a: op(a, "cp", "async", "commit_group", no=("bulk",)),
        "cp.async.wait_group": lambda a: op(a, "cp", "async", no=("bulk",)) and bool(
            a.quals & {"wait_group", "wait_all"}),
        "cp.async.mbarrier.arrive": lambda a: op(a, "cp", "async", "mbarrier", "arrive"),
        "cp.async.bulk.commit_group": lambda a: op(a, "cp", "async", "bulk", "commit_group"),
        "cp.async.bulk.wait_group": lambda a: op(a, "cp", "async", "bulk", "wait_group"),
        "cp.async.bulk.global_to_shared": lambda a: op(a, "cp", "async", "bulk", "global",
                                                       no=("tensor", "multicast::cluster", "prefetch"))
        and bool(a.quals & {"shared::cluster", "shared::cta"}) and a.ins.quals.index("global") > 2,
        "cp.async.bulk.multicast": lambda a: op(a, "cp", "async", "bulk", "multicast::cluster", no=("tensor",)),
        "cp.async.bulk.shared_to_cluster": lambda a: op(a, "cp", "async", "bulk", "shared::cluster",
                                                        "shared::cta", no=("tensor",)),
        "cp.async.bulk.shared_to_global": lambda a: op(a, "cp", "async", "bulk", "global", "shared::cta",
                                                       no=("tensor", "prefetch"))
        and a.ins.quals.index("global") == 2,
        "cp.async.bulk.prefetch": lambda a: op(a, "cp", "async", "bulk", "prefetch", no=("tensor",)),
        "cp.async.bulk.prefetch.tensor": lambda a: op(a, "cp", "async", "bulk", "prefetch", "tensor"),
        "cp.async.bulk.tensor.im2col": lambda a: op(a, "cp", "async", "bulk", "tensor")
        and any(q.startswith("im2col") for q in a.quals),
        "cp.async.bulk.tensor.multicast": lambda a: op(a, "cp", "async", "bulk", "tensor", "multicast::cluster"),
        "cp.async.bulk.tensor.store": lambda a: op(a, "cp", "async", "bulk", "tensor", "global", no=("prefetch",))
        and a.ins.quals.index("global") < (a.ins.quals.index("shared::cta") if "shared::cta" in a.quals else 99),
        "cp.async.bulk.tensor.tile": lambda a: op(a, "cp", "async", "bulk", "tensor", "tile", no=("prefetch",))
        and bool(a.quals & {"shared::cluster", "shared::cta"}),
        "cp.reduce.async.bulk": lambda a: op(a, "cp", "reduce", "async", "bulk", no=("tensor",)),
        "cp.reduce.async.bulk.tensor": lambda a: op(a, "cp", "reduce", "async", "bulk", "tensor"),
        "fence.op_restrict": lambda a: op(a, "fence", "mbarrier_init"),
        "fence.proxy.alias": lambda a: op(a, "fence", "proxy", "alias"),
        "fence.proxy.async": lambda a: a.ins.op == "fence" and "proxy" in a.quals
        and any(q.startswith("async") for q in a.quals),
        "fence.proxy.tensormap": lambda a: a.ins.op == "fence" and "proxy" in a.quals
        and any(q.startswith("tensormap") for q in a.quals),
        "fence.sync_restrict": lambda a: a.ins.op == "fence" and any(q.startswith("sync_restrict") for q in a.quals)
        and "proxy" not in a.quals,
        "mbarrier.arrive": lambda a: op(a, "mbarrier", "arrive", no=("expect_tx",)),
        "mbarrier.arrive.expect_tx": lambda a: op(a, "mbarrier", "arrive", "expect_tx"),
        "mbarrier.arrive.shared::cluster": lambda a: a.ins.op == "mbarrier" and bool(
            a.quals & {"arrive", "arrive_drop"}) and "shared::cluster" in a.quals,
        "mbarrier.arrive_drop": lambda a: op(a, "mbarrier", "arrive_drop"),
        "mbarrier.complete_tx": lambda a: op(a, "mbarrier", "complete_tx"),
        "mbarrier.expect_tx": lambda a: op(a, "mbarrier", "expect_tx", no=("arrive",)),
        "mbarrier.init": lambda a: op(a, "mbarrier", "init"),
        "mbarrier.inval": lambda a: op(a, "mbarrier", "inval"),
        "mbarrier.pending_count": lambda a: op(a, "mbarrier", "pending_count"),
        "mbarrier.scope.cluster": lambda a: op(a, "mbarrier", "cluster"),
        "mbarrier.test_wait": lambda a: op(a, "mbarrier", "test_wait"),
        "mbarrier.try_wait": lambda a: op(a, "mbarrier", "try_wait"),
        "mbarrier.wait.parity": lambda a: a.ins.op == "mbarrier" and "parity" in a.quals,
        "tensormap.cp_fenceproxy": lambda a: op(a, "tensormap", "cp_fenceproxy"),
        "tensormap.replace": lambda a: op(a, "tensormap", "replace"),
        "wgmma.commit_group": lambda a: op(a, "wgmma", "commit_group"),
        "wgmma.fence": lambda a: op(a, "wgmma", "fence"),
        "wgmma.mma_async": lambda a: op(a, "wgmma", "mma_async"),
        "wgmma.wait_group": lambda a: op(a, "wgmma", "wait_group"),
    }
    if fid in simple:
        return simple[fid]
    if head == "fence":
        k, v = parts[1], parts[2]
        if k == "scope":
            return lambda a: a.ins.op == "fence" and v in a.quals and "proxy" not in a.quals
        if k == "sem":
            return lambda a: a.ins.op == "fence" and v in a.quals and "proxy" not in a.quals \
                and not any(q.startswith("sync_restrict") for q in a.quals)
    if head == "space":
        want = {"const": ("const",), "global": ("global",), "local": ("local",), "param": ("param",),
                "shared": ("shared::cta",), "shared::cluster": ("shared::cluster-local", "shared::cluster-remote")}
        return lambda a: a.space in want[rest]
    raise KeyError(f"no rule for feature {fid}")


# ------------------------------------------------------------------------------- which dimensions are valid

def valid_scopes(fid: str) -> tuple:
    if fid == "mbarrier.scope.cluster":
        return ("cluster",)
    if fid == "red.scope":  # .cluster is the feature red.scope.cluster
        return ("cta", "gpu", "sys")
    if fid in ("ld.volatile", "st.volatile"):  # no scope qualifier: volatile is relaxed at .sys
        return ()
    if fid.startswith(("mbarrier.", "barrier.cluster")) or fid in ("fence.sync_restrict", "fence.op_restrict"):
        return ("cta", "cluster") if fid.startswith("mbarrier.") and fid not in (
            "mbarrier.init", "mbarrier.inval") else ()
    if re.match(r"(atom|red)\.(sem|global|shared|generic|b128|half|vector|scope$)", fid) or \
            re.match(r"(ld|st)\.(sem|global$|shared|generic|volatile)", fid) or \
            fid.startswith(("fence.sem", "fence.proxy.tensormap")):
        return SCOPES
    return ()


def valid_spaces(fid: str) -> tuple:
    if fid in ("atom.vector", "red.vector"):  # vector atomics exist for global memory only (9.7.13.5)
        return ("global",)
    if re.match(r"(atom|red)\.(scope|sem|half|vector|b128)", fid) or fid in ("red.scope", "red.scope.cluster"):
        return MEM_SPACES
    if re.match(r"(ld|st)\.(scope|sem)", fid):
        return MEM_SPACES
    if fid in ("ld.volatile", "st.volatile"):
        return MEM_SPACES
    if fid in ("ld.generic", "st.generic"):  # a generic address of the own CTA's shared memory, or of global memory
        return ("global", "shared::cta")
    return ()


def placements_matter(fid: str) -> bool:
    return bool(valid_scopes(fid)) or fid.startswith(("bar", "barrier", "mbarrier", "fence", "space.shared"))


# ------------------------------------------------------------------------------------------------- the API

@dataclass
class Feature:
    id: str
    kind: str
    how: str
    exempt: str | None
    tests: list[str]
    scopes: set
    spaces: set
    placements: set


@lru_cache(maxsize=None)
def coverage() -> list[dict]:
    return yaml.safe_load(COVERAGE.read_text())


def features(tests: list[str] | None = None) -> list[Feature]:
    tests = tests if tests is not None else all_tests()
    out = []
    for e in coverage():
        fid = e["feature"]
        r = rule(fid)
        if r is None:
            out.append(Feature(fid, e["kind"], e.get("how", ""), "register operation: no memory event and no "
                               "litmus form (D27)", [], set(), set(), set()))
            continue
        ts, sc, sp, pl = [], set(), set(), set()
        for tid in tests:
            hits = [a for a in facts(tid).accesses if r(a)]
            if hits:
                ts.append(tid)
                sc |= {a.scope or "default" for a in hits}
                sp |= {a.space for a in hits if a.space}
                pl.add(facts(tid).placement)
        out.append(Feature(fid, e["kind"], e.get("how", ""), None, ts, sc, sp, pl))
    return out


def main() -> int:
    fs = features()
    if len(sys.argv) > 1:
        for f in fs:
            if f.id in sys.argv[1:]:
                print(f"{f.id}: {len(f.tests)} tests; scopes {sorted(f.scopes)}; spaces {sorted(f.spaces)}; "
                      f"placements {sorted(f.placements)}")
                for t in f.tests:
                    print(f"  {t}")
        return 0
    for f in fs:
        tag = f"exempt: {f.exempt}" if f.exempt else f"{len(f.tests)} tests"
        print(f"{f.id:36} {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Check by bounded model finding whether a surviving mutant of ptx87.als is equivalent to the model.

A mutant that no litmus test kills either changes nothing (it is equivalent), or the suite has a gap. Instead of an
argument by hand, this tool asks Alloy: it writes a module that holds every `fun` and `pred` of ptx87.als twice,
once as is and once with the mutation applied and an `_m` suffix on every name, and checks that the two versions
of `ptx_mm`, `undefined` and `mixed_size_race` agree on every execution with at most N events that has the shape
of a translated litmus test (`emitted` below). A counterexample is
an execution that a new litmus test can pin. A mutant that changes a fact is checked with the model inlined and
the fact in both versions (fact_module).

    python3 tools/litmus/mutant_equiv.py R-cause_base-closure-386      # bounds 4 and 5, in the dev container
    python3 tools/litmus/mutant_equiv.py --bounds 4 --limit 3600 ID...

Writes build/mutation/equiv/<id>.txt (one line per command: UNSAT, SAT or no result), records the verdict in
models/ptx87/equiv/mutants.csv (read by mutate.py --report) and prints a summary. Uses
models/ptx87/equiv/check.sh (kissat; counterexamples kept in build/ptx87-equiv/cex/).
"""
import argparse
import csv
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "models" / "ptx87" / "ptx87.als"
EQUIV = ROOT / "models" / "ptx87" / "equiv"
OUT = ROOT / "build" / "mutation" / "equiv"
RESULTS = EQUIV / "mutants.csv"   # the verdict of the last full check of each mutant
SCOPES = {4: "for 4 but 6 Scope, 3 Address, 3 Access, 4 Int", 5: "for 5 but 7 Scope, 3 Address, 3 Access, 4 Int"}
PREDS = ("ptx_mm", "undefined", "mixed_size_race")

# The facts of ptx87.als accept executions that no program has: a store that is also a proxy fence, `issue` edges
# between ordinary events, a complete-tx that orders itself. A mutant may differ only there, which no test can
# show. `emitted` states what tools/litmus/to_alloy87.py always emits, and the checks compare the two versions on
# executions it accepts only. The sanity runs show that the shape still admits the asynchronous features.
SHAPE = """\
fun PlainScope : Scope { Scope - CtaScope - ClusterScope - Thread }
pred emitted {
  // the scope tree: system, GPUs, clusters (in every GPU or in none), CTAs, threads and asynchronous units
  System in PlainScope
  (PlainScope - System) in System.subscope
  System.subscope in PlainScope
  ClusterScope in (PlainScope - System).subscope
  CtaScope in (PlainScope - System + ClusterScope).subscope
  some ClusterScope => CtaScope in ClusterScope.subscope
  Thread in CtaScope.subscope
  ClusterScope.subscope in CtaScope
  CtaScope.subscope in Thread
  // aliases: views of one physical location, in its state space and with its owner
  no alias.alias
  all a: Address | a.aliases.space = a.space and a.aliases.owner = a.owner
  // shared memory is used by the threads of its CTA's cluster (of its CTA when there are no clusters)
  all e: MemoryEvent | e.address.space = Shared =>
    (some ClusterScope => e.cluster_of = e.address.owner.~subscope else e.cta_of = e.address.owner)
  // texture and surface memory is global memory
  proxy.(Texture + Surface).address.space in Global
  // local memory is used by its own thread only
  all e: MemoryEvent - thd.AsyncUnit | e.address.space = Local => e.address.owner = e.thd
  // only generic operations and the reductions of cp.reduce.async.bulk are strong (texture, surface and constant
  // instructions take no order qualifier); weak operations have the scope of their thread
  MemoryEvent - Weak in proxy.(Generic + Async)
  all e: MemoryEvent & Weak | e.scope = e.thd
  // proxy fences: fence.proxy.<kind> (PlainProxyFence) and fence.proxy.{tensormap,async}::generic.{release,acquire}
  ProxyFence in PlainProxyFence + FenceRel + FenceAcq
  PlainProxyFence in ProxyFence
  all f: PlainProxyFence | (some p: Proxy - Generic | f.dirs = p->Generic + Generic->p)
    or f.dirs = Generic->(Async + Texture + Surface + Constant)   // after griddepcontrol.wait (D46)
  all f: ProxyFence - PlainProxyFence | some p: TensorMap + Async | f.dirs = Generic->p
  pspace in PlainProxyFence -> Space
  paddr in FenceAcq -> Address
  // completions go from an asynchronous unit to a marker or to another unit
  done in thd.AsyncUnit -> (Marker + thd.AsyncUnit)
  no done & thd.~thd
  // an issuing thread marks the issue point; the first event of an asynchronous unit is issued
  issue in (Marker & thd.(Thread - AsyncUnit)) -> AsyncUnit.start
  // griddepcontrol.wait is a marker in an ordinary thread
  gdep in Event -> (Marker & thd.(Thread - AsyncUnit))
  // the complete-tx of an asynchronous instruction: a release update of an mbarrier in the unit, ordering that
  // instruction's other operations
  TxAnchor in Release & MbarEv & thd.AsyncUnit
  no txops & iden
  // the restricted fences are .cluster fences
  SyncRestrictCta + SyncRestrictCluster + OpRestrictInit in scope.ClusterScope
  // writes: st, red, atom (generic), sust, sured, suatom (surface), asynchronous copies (async); the texture and
  // constant proxies only read
  Write.proxy in Generic + Surface + Async
  // operations in the async proxy are performed by asynchronous units
  proxy.Async in thd.AsyncUnit
  // asynchronous units perform memory operations and proxy fences only
  thd.AsyncUnit in MemoryEvent + PlainProxyFence
  // an mbarrier object is in shared memory, and every operation on it is a generic one; mbarrier.init is a plain
  // write of an ordinary thread
  Mbar in space.Shared
  MbarEv.proxy in Generic
  MbarInit in (Write - Release - Read.rmw) & thd.(Thread - AsyncUnit)
  // the issue, completion and grid-dependency edges never form a cycle with program order
  acyclic[po + issue + done + gdep]
  // an access (D6) is one instruction: one thread, one kind, one scope, one proxy, distinct granules
  all a: Access | lone acc.a.thd and lone acc.a.scope and lone acc.a.proxy
  all a: Access | acc.a in Read or acc.a in Write
  all a: Access | (acc.a in Acquire or no acc.a & Acquire) and (acc.a in Release or no acc.a & Release)
  acc.~acc & address.~address in iden
  all a: Access | no acc.a or not lone acc.a
  all a: Access | lone acc.a.address.space and lone acc.a.address.owner
  // texture, surface and constant operations are instructions of ordinary threads
  proxy.(Texture + Surface + Constant) in thd.(Thread - AsyncUnit)
  // strong async-proxy operations are the read-modify-writes of cp.reduce.async.bulk
  (MemoryEvent - Weak) & proxy.Async in Read.rmw + rmw.Write
  // in an asynchronous unit, mbarrier operations are read-modify-write updates
  MbarEv & thd.AsyncUnit in Read.rmw + rmw.Write
  // a dependency ends at a memory operation or at a bar.sync whose operands come from registers
  Read.dep in MemoryEvent + BarrierArrive
  // no location is owned by an asynchronous unit
  no Address.owner & AsyncUnit
  // a completion ends at a marker or at the first event of a unit; units never acquire
  Event.done in Marker + AsyncUnit.start
  no Acquire & thd.AsyncUnit
  // operations on an mbarrier object: init, inval (the state of mb_inval), read-modify-write updates and waits
  MbarEv & Write in MbarInit + Read.rmw + { w: Write | w.ph = -1 and w.pend = 0 and w.expc = 0 and w.tx = 0 }
  MbarEv & Read in MbarWait + rmw.Write
  // a wait names its phase by a parity or by a state token, never both
  all r: MbarWait | (one r.wpar and no r.wtok) or (one r.wtok and no r.wpar)
  MbarWait.wpar in 0 + 1
  // mixed-size accesses come from the loads and stores of ordinary threads (never an mbarrier operation or a
  // read-modify-write), and the events of one access lie on different physical locations
  acc.Access in thd.(Thread - AsyncUnit) - MbarEv - Read.rmw - rmw.Write
  no acc.Access.address & Mbar
  acc.~acc & address.(iden + alias).~(address.(iden + alias)) in iden
  // tensormap-proxy reads are made by the asynchronous units of cp.async.bulk.tensor
  proxy.TensorMap in Read & thd.AsyncUnit
  // restricted fences: .sync_restrict::shared::cta and .op_restrict release, .sync_restrict::shared::cluster
  // acquires; .op_restrict is never a proxy fence
  SyncRestrictCta + OpRestrictInit in FenceRel
  SyncRestrictCluster in FenceAcq
  no OpRestrictInit & ProxyFence
  // mbarrier.init and mbarrier.inval are weak plain writes of the value 0
  all w: (MbarEv & Write) - Read.rmw | w.val = 0
  (MbarEv & Write) - Read.rmw in Weak - Release
  // the events of a mixed-size access are consecutive; only the other elements of the same vector instruction
  // (same kind, proxy, scope and order) may come between them
  all a: Access, e: Event | (some acc.a & ^po.e and some acc.a & e.^po) => (e in MemoryEvent and
    e.proxy = (acc.a).proxy and e.scope = (acc.a).scope and (e in Read iff acc.a in Read) and
    (e in Acquire + Release iff acc.a in Acquire + Release))
  // an alias view maps each granule to one granule
  all a: Address | lone a.alias
  // a mixed-size access covers a whole location (the litmus syntax names a location or one granule), so two
  // accesses that overlap cover the same physical granules
  all a1, a2: Access | let g1 = acc.a1.address.(alias + (Address - alias.Address) <: iden),
    g2 = acc.a2.address.(alias + (Address - alias.Address) <: iden) | some g1 & g2 => g1 = g2
  // waits are plain reads; mbarrier.init (.shared::cta only) initializes an mbarrier of its own CTA
  no MbarWait & rmw.Write
  all w: MbarInit | w.address.owner = w.cta_of
  // the async-proxy writes of a copy are in a unit that the implicit proxy fence after the copy's reads starts
  all w: Write & proxy.Async | w.thd.start in PlainProxyFence.done - Event.issue
  // a unit holds some memory operation, and its implicit proxy fences are generic <-> async for every state space
  all u: AsyncUnit | some thd.u & MemoryEvent
  all f: PlainProxyFence & thd.AsyncUnit | f.dirs = Async->Generic + Generic->Async and no f.pspace
  // the units a copy's proxy fence starts hold the async-proxy writes (or reductions), the implicit proxy fence
  // and the complete-tx; a unit reads shared memory of its own CTA only; dependencies in a unit go from a read
  // to a write (cp.async)
  all u: AsyncUnit | u.start in PlainProxyFence.done => thd.u in proxy.Async + PlainProxyFence + MbarEv
  all r: Read & thd.AsyncUnit | r.address.space = Shared => r.address.owner = r.cta_of
  dep & (thd.AsyncUnit -> Event) in Read -> Write
  // completions start at a unit's implicit proxy fence or at the last write of a cp.async unit; a unit started
  // by a completion hangs off an issued unit; a unit's proxy fences have the unit as scope
  done.Event in thd.AsyncUnit & (PlainProxyFence + (Write & proxy.Generic))
  all u: AsyncUnit | u.start in Event.done => (done.(u.start)).thd.start in Event.issue
  all f: PlainProxyFence & thd.AsyncUnit | f.scope = f.thd
  // an issued unit with a proxy fence holds the source reads of a copy or the operand reads of a wgmma (and a
  // tensor copy's tensor-map read)
  all u: AsyncUnit | (u.start in Event.issue and some thd.u & PlainProxyFence) =>
    ((thd.u in (Read & proxy.(Async + TensorMap)) + PlainProxyFence and some thd.u & Read & proxy.Async)
     or thd.u in (MemoryEvent & proxy.Generic & Weak) + PlainProxyFence)   // cp.async (D45)
  // a copy's writes to shared memory are by a unit in the CTA that owns it (D21); the reads of a write unit are
  // those of reductions and of the complete-tx
  all w: Write & proxy.Async | w.address.space = Shared => w.address.owner = w.cta_of
  all u: AsyncUnit | u.start in PlainProxyFence.done => thd.u & Read in rmw.Write + MbarEv
  // a unit never starts with its implicit proxy fence; a copy reads global or shared memory, and its writes to
  // global memory are by a unit in the issuing CTA (D21)
  no PlainProxyFence & AsyncUnit.start
  (Read & proxy.Async & thd.AsyncUnit).address.space in Global + Shared
  all f: PlainProxyFence, w: Write & proxy.Async | (f->w.thd.start in done and w.address.space = Global) =>
    w.cta_of = f.cta_of
  // a bulk copy never goes from global memory to global memory
  all f: PlainProxyFence, w: Write & proxy.Async | f->w.thd.start in done =>
    no (f.thd.~thd & Read & proxy.Async).address.space & w.address.space & Global
  // a marker issues one unit, except wgmma.fence, which issues the units of the wgmma instructions after it; the
  // write that ends a cp.async unit completes into an mbarrier arrive or a wait
  all m: Marker | lone m.issue or thd.(m.issue.thd) in (Read & proxy.Async) + PlainProxyFence
  done & (Write -> Event) in Write -> (MbarEv + Marker)
  all w: Write & done.Event | some w.thd.~thd & Read & proxy.Generic
  // atomic vector accesses: the weak-free loads or stores of one ordinary thread, at least two events (D43)
  vacc.VecAccess in thd.(Thread - AsyncUnit) - Weak - MbarEv - Read.rmw - rmw.Write
  all v: VecAccess | lone vacc.v.thd and not lone vacc.v and (vacc.v in Read or vacc.v in Write)
  // its events are generic, consecutive in program order and on different memory
  vacc.VecAccess in proxy.Generic
  all v: VecAccess, e: Event | (some vacc.v & ^po.e and some vacc.v & e.^po) => e in vacc.v
  vacc.~vacc & address.(iden + alias).~(address.(iden + alias)) in iden
  // only waits acquire an mbarrier
  MbarEv & Acquire in MbarWait
  // an access goes through one view: all its granules through a virtual alias, or none
  all a: Access | acc.a.address in alias.Address or no acc.a.address & alias.Address
  // griddepcontrol.wait: from the last event of each thread of the previous grid to a wait of another thread
  no gdep & thd.~thd
  no (gdep.Event).po
  // asynchronous units never access local memory
  no (MemoryEvent & thd.AsyncUnit).address.space & Local
  // a unit that is neither issued nor started by a completion holds the operand reads of a wgmma
  all u: AsyncUnit | u.start not in Event.(issue + done) => thd.u in (Read & proxy.Async) + PlainProxyFence
}
"""
SANITY = ["sanity_shape_tx: run { emitted and ptx_mm and some TxAnchor and some issue } for 5 but 7 Scope, "
          "3 Address, 3 Access, 4 Int",
          "sanity_shape_pf: run { emitted and ptx_mm and some ProxyFence and some proxy.Async } for 5 but 7 Scope, "
          "3 Address, 3 Access, 4 Int"]


def defs(text):
    """The fun and pred definitions of the model, as (name, text), in order."""
    lines, out, cur, depth, opened = text.split("\n"), [], None, 0, False
    for line in lines:
        code = line.split("//")[0]
        if cur is None:
            m = re.match(r"^(?:fun|pred)\s+(\w+)", code)
            if not m:
                continue
            cur, depth, opened = [m.group(1), []], 0, False
        cur[1].append(line)
        depth += code.count("{") - code.count("}")
        opened = opened or "{" in code
        if opened and depth <= 0:
            out.append((cur[0], "\n".join(cur[1])))
            cur = None
    return out


# executions with no undefined behaviour and no mixed-size race, where the axioms decide the verdict alone
DEFINED = "not undefined and not mixed_size_race"

CORE = ("no AsyncUnit and no Marker and no MbarEv and no acc and no vacc and no SyncRestrictCta + SyncRestrictCluster + "
        "OpRestrictInit and ProxyFence in PlainProxyFence and no pspace and Address.space in Global + Shared")


def module(m, bounds, core=False, defined=False):
    text = MODEL.read_text()
    if text.count(m["find"]) != 1:
        raise SystemExit(f"{m['id']}: its text does not occur once")
    mutated = text.replace(m["find"], m["replace"], 1)
    orig_defs, mut_defs = defs(text), defs(mutated)
    if [n for n, _ in orig_defs] != [n for n, _ in mut_defs]:
        raise SystemExit(f"{m['id']}: the mutation changes the definitions themselves")
    if sum(a != b for (_, a), (_, b) in zip(orig_defs, mut_defs)) == 0:
        return fact_module(m, text, mutated, bounds, core, defined)
    names = {n for n, _ in orig_defs}
    pat = re.compile(r"\b(" + "|".join(sorted(names, key=len, reverse=True)) + r")\b")
    body = [pat.sub(lambda x: x.group(1) + "_m", t) for _, t in mut_defs]
    # the mutant again, with the coherence order read from CoW.tco instead of co (suffix _t)
    body_t = [re.sub(r"\bco\b", "(CoW.tco)", pat.sub(lambda x: x.group(1) + "_t", t)) for _, t in mut_defs]
    # the model (not mutated) with the Fence-SC order read from ScW.tsc instead of sc (suffix _s), for the
    # mutants marked `witness: sc`
    body_s = [re.sub(r"\bsc\b", "(ScW.tsc)", pat.sub(lambda x: x.group(1) + "_s", t)) for _, t in orig_defs] \
        if m.get("witness") == "sc" else []
    out = [f"// The mutant {m['id']} of ptx87.als ({m['rule']}): every fun and pred, renamed with _m, and again",
           "// with co read from CoW.tco, renamed with _t.",
           "module mutant", "open ptx87", "", SHAPE, "one sig CoW { tco: Write -> Write }"] + \
        (["one sig ScW { tsc: FenceSC -> FenceSC }"] if body_s else []) + [""] + \
        body + [""] + body_t + [""] + body_s + [""] + SANITY
    for b in bounds:
        for p in PREDS:
            cond = f"(emitted and {CORE})" if core else "emitted"
            cond = f"({cond} and {DEFINED})" if defined else cond
            out.append(f"eq_{p}_{b}: check {{ {cond} => ({p} <=> {p}_m) }} {SCOPES[b]}")
    if core or defined:
        return "\n".join(out) + "\n"
    # Coherence order is a witness: the solver picks co, and ptx87.als only uses its closure ^co (and acyclic[co],
    # rf + co in same_location_r, which ^co also satisfies), so a test's verdict is the same with co and with ^co.
    # A mutant that reads co itself can differ only on executions whose co is not transitive. It judges every
    # program as the model does if (cw) it agrees with the model when co is transitive, and (cm) whenever it
    # accepts an execution it also accepts it with co replaced by ^co.
    for b in bounds:
        for p in PREDS:
            out.append(f"cw_{p}_{b}: check {{ (emitted and co = ^co) => ({p} <=> {p}_m) }} {SCOPES[b]}")
            out.append(f"cm_{p}_{b}: check {{ (emitted and CoW.tco = ^co and {p}_m) => {p}_t }} {SCOPES[b]}")
    # Fence-SC order is a witness too: the solver picks sc among the total orders of the morally strong fence.sc
    # pairs. With at most two fence.sc there are two such orders, sc and ~sc, so the mutant judges every such
    # program as the model does if, whenever it accepts an execution (alone, or with a mixed-size race), the model
    # accepts the same execution with sc or with ~sc.
    if m.get("witness") == "sc":
        for b in bounds:
            for p in ("ptx_mm", "ptx_mm and mixed_size_race"):
                q, o = (re.sub(r"\b(?!and\b)(\w+)", r"\1" + sfx, p) for sfx in ("_m", "_s"))
                o = "(" + p + ") or (" + o + ")"
                name = p.replace(" and ", "_")
                out.append(f"sm_{name}_{b}: check {{ (emitted and #FenceSC =< 2 and ScW.tsc = ~sc and {q}) => "
                           f"({o}) }} {SCOPES[b]}")
    return "\n".join(out) + "\n"


def fact_module(m, text, mutated, bounds, core, defined=False):
    """A mutant that changes a fact: the module holds the model with that fact taken out, and the fact as it is
    (fact_o) and as mutated (fact_m) as predicates. The two versions judge every execution alike if, on executions
    of the shape `emitted`, the model's verdicts are the same under either fact."""
    start = text.index(m["find"])
    head = text.rfind("\nfact ", 0, start) + 1
    if head == 0:
        raise SystemExit(f"{m['id']}: the mutation is in no fun, pred or fact")
    depth, end = 0, head
    for k in range(head, len(text)):
        depth += {"{": 1, "}": -1}.get(text[k], 0)
        if text[k] == "}" and depth == 0:
            end = k + 1
            break
    shift = len(m["replace"]) - len(m["find"])
    block_o, block_m = text[head:end], mutated[head:end + shift]
    if not block_m.endswith("}") or block_o.replace(m["find"], m["replace"], 1) != block_m:
        raise SystemExit(f"{m['id']}: the mutation spans more than one fact")
    name = re.match(r"fact\s+(\w+)", block_o).group(1)
    model = text[:head] + text[end:]
    model = re.sub(r"^module\s+\w+", "module mutant", model, count=1, flags=re.M)
    body = lambda b, n: re.sub(r"^fact\s+\w+", f"pred {n}", b)
    out = [f"// The mutant {m['id']} of ptx87.als ({m['rule']}): the model with fact {name} as two predicates,",
           "// fact_o (as it is) and fact_m (mutated).", model, body(block_o, "fact_o"), body(block_m, "fact_m"),
           "", SHAPE, ""] + [s.replace("{ emitted", "{ fact_o and emitted") for s in SANITY]
    for b in bounds:
        for p in PREDS:
            cond = f"(emitted and {CORE})" if core else "emitted"
            cond = f"({cond} and {DEFINED})" if defined else cond
            out.append(f"eq_{p}_{b}: check {{ {cond} => ((fact_o and {p}) <=> (fact_m and {p})) }} {SCOPES[b]}")
    return "\n".join(out) + "\n"


def validate(jobs):
    """Check that every translated litmus query satisfies `emitted`: each query fixes its program in a fact and
    leaves the execution free, so `check { emitted }` with the query's own scope must find no counterexample."""
    import concurrent.futures as cf
    out = ROOT / "build" / "mutation" / "emitted"
    out.mkdir(parents=True, exist_ok=True)
    paths = []
    queries = ROOT / "tests" / "litmus" / "alloy-ptx87"
    for q in sorted(queries.rglob("*.als")):
        text = q.read_text()
        scope = re.search(r"^run test \{.*\} (for .*?)(?://.*)?$", text, re.M).group(1).strip()
        p = out / (re.sub(r"[^A-Za-z0-9_]", "_", str(q.relative_to(queries))) + ".als")
        p.write_text(text + "\n" + SHAPE + f"\nemitted_ok: check {{ emitted }} {scope}\n")
        paths.append((q, p))
    env = dict(os.environ, JOBS="1")
    def one(qp):
        r = subprocess.run([str(EQUIV / "check.sh"), str(qp[1])], capture_output=True, text=True, env=env)
        return qp[0], r.stdout.strip()
    bad = 0
    with cf.ThreadPoolExecutor(int(jobs)) as ex:
        for q, res in ex.map(one, paths):
            if "UNSAT" not in res:
                bad += 1
                print(f"{q.relative_to(ROOT)}: {res}", flush=True)
    print(f"{len(paths)} queries, {bad} not accepted by emitted")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--validate", action="store_true", help="check `emitted` against every translated query")
    ap.add_argument("--core", action="store_true",
                    help="search only executions without asynchronous units, mbarriers, mixed-size accesses or "
                         "restricted fences (counterexamples that tools/litmus/cex_litmus.py can write back)")
    ap.add_argument("--defined", action="store_true",
                    help="compare only executions with no undefined behaviour and no mixed-size race")
    ap.add_argument("--bounds", default="4,5")
    ap.add_argument("--limit", default="3600")
    ap.add_argument("--jobs", default="8")
    a = ap.parse_args()
    if a.validate:
        return validate(a.jobs)
    bounds = [int(b) for b in a.bounds.split(",")]
    mutants = {m["id"]: m for f in ("mutants.yaml", "mutants-reword.yaml")
               for m in yaml.safe_load((ROOT / "models" / "ptx87" / f).read_text()) or []}
    OUT.mkdir(parents=True, exist_ok=True)
    for mid in a.ids:
        m = mutants[mid]
        if m["model"] != "alloy":
            print(f"{mid}: not an Alloy mutant")
            continue
        src = module(m, bounds, a.core, a.defined)
        tag = "_core" if a.core else "_defined" if a.defined else ""
        path = OUT / f"mut_{re.sub(r'[^A-Za-z0-9_]', '_', mid)}{tag}.als"
        path.write_text(src)
        env = dict(os.environ, LIMIT=a.limit, JOBS=a.jobs)
        r = subprocess.run([str(EQUIV / "check.sh"), str(path)], capture_output=True, text=True, env=env)
        res = [l for l in r.stdout.splitlines() if l[:3] in ("eq_", "cw_", "cm_", "sm_")]
        (OUT / f"{mid}{tag.replace('_', '.')}.txt").write_text("\n".join(res) + "\n")
        ok = lambda k: all("UNSAT" in l for l in res if l.startswith(k)) and any(l.startswith(k) for l in res)
        bad = [l for l in r.stdout.splitlines() if l.startswith("sanity_") and "WRONG" in l]
        verdict = "no result" if bad or any("no result" in l for l in res if l.startswith("eq_")) else \
            "equivalent" if ok("eq_") else \
            "equivalent up to the coherence witness" if ok("cw_") and ok("cm_") else \
            "equivalent up to the Fence-SC witness, with at most two fence.sc" if ok("sm_") else "differs"
        if a.core:   # agreement on the core fragment proves nothing about the whole model
            verdict = {"equivalent": "agrees on the core fragment", "differs": "differs on the core fragment"}.get(
                verdict, verdict)
        if a.defined:
            verdict = {"equivalent": "agrees on defined executions", "differs": "differs on defined executions"}.get(
                verdict, verdict)
        res = [l for l in res if l.startswith("eq_")] if verdict == "equivalent" else res
        print(f"{mid}: {verdict} ({'; '.join(res)})", flush=True)
        if not (a.core or a.defined) and verdict != "no result":
            record(mid, verdict, bounds)
    return 0


def record(mid, verdict, bounds):
    """Keep the verdict of a full check in RESULTS (one row per mutant), which mutate.py --report reads."""
    rows = {}
    if RESULTS.exists():
        with open(RESULTS, newline="") as f:
            rows = {r["id"]: r for r in csv.DictReader(f)}
    rows[mid] = {"id": mid, "verdict": verdict, "bounds": " and ".join(str(b) for b in bounds)}
    with open(RESULTS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["id", "verdict", "bounds"], lineterminator="\n")
        w.writeheader()
        w.writerows(rows[k] for k in sorted(rows))


if __name__ == "__main__":
    sys.exit(main())

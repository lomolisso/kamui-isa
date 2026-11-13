#!/usr/bin/env python3
"""Turn the counterexamples of tools/litmus/mutant_equiv.py into litmus tests, and run each on the PTX 8.7 model and
on the mutant.

A counterexample of mutant_equiv.py is one execution that the model and a mutant judge differently. That does not
yet show a program whose verdict changes: the solver also picks the witnesses (coherence order, Fence-SC order, the
write each read takes its value from), and another choice may give the same outcome under both. This script writes
the counterexample's program as a litmus test whose condition is the execution's outcome (every value read and,
where coherence order fixes it, the final value of every location), then asks Alloy for the verdict of the test
under the model and under the mutant, each over every execution of the program. Different verdicts: the test kills
the mutant.

    python3 tools/litmus/cex_litmus.py R-po_loc-closure-241 ...     # in the dev container, after mutant_equiv.py

Reads build/ptx87-equiv/cex/mut_<id>/<command>/ (Alloy's text instances). Writes the tests to
build/mutation/gen/<id>/<command>.litmus and prints, per counterexample, the two verdicts or why the execution has
no litmus form (asynchronous units, mbarrier objects and mixed-size accesses are not written back).
"""
import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import litmus          # noqa: E402
import to_alloy87      # noqa: E402
import run_formal      # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CEX = ROOT / "build" / "ptx87-equiv" / "cex"
GEN = ROOT / "build" / "mutation" / "gen"
MODEL = ROOT / "models" / "ptx87"


class Unconvertible(Exception):
    pass


def instance(path: Path) -> dict:
    """Alloy's text instance: {(sig, field or None): [tuple of atoms]} with the `ptx87/` prefix removed."""
    rel = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^ptx87/([A-Za-z]+)(?:<:(\w+))?=\{(.*)\}$", line.strip())
        if m:
            sig, field, body = m.groups()
            body = re.sub(r"\b(Generic|Async|TensorMap|Texture|Surface|Constant|Global|Shared|Local|Const|Param)\$0\b",
                          r"\1", body.replace("ptx87/", ""))
            rel[(sig, field)] = [tuple(x.strip().split("->")) for x in body.split(", ") if x.strip()]
    return rel


def to_litmus(rel: dict, name: str) -> str:
    sets = {s: {t[0] for t in v} for (s, f), v in rel.items() if f is None}
    S = lambda s: sets.get(s, set())
    F = lambda s, f: rel.get((s, f), [])
    one = lambda s, f: {t[0]: t[1] for t in F(s, f)}
    for s in ("AsyncUnit", "Marker", "MbarEv", "SyncRestrictCta", "SyncRestrictCluster", "OpRestrictInit", "TxAnchor"):
        if S(s):
            raise Unconvertible(f"has {s}")
    if F("MemoryEvent", "acc"):
        raise Unconvertible("mixed-size accesses")
    if S("ProxyFence") - S("PlainProxyFence"):
        raise Unconvertible("a release or acquire proxy fence")
    parent = {c: p for p, c in F("Scope", "subscope")}
    start, po = one("Thread", "start"), one("Event", "po")
    scope, addr, proxy, val = one("Event", "scope"), one("MemoryEvent", "address"), one("MemoryEvent", "proxy"), \
        one("MemoryEvent", "val")
    space, owner, init = one("Address", "space"), one("Address", "owner"), one("Address", "init")
    alias = one("Address", "alias")
    rmw = one("Read", "rmw")
    if {t for t in F("Read", "dep")} - set(F("Read", "rmw")):
        raise Unconvertible("dependencies other than read-modify-write")
    # placement
    threads = sorted(start)
    ctas, clusters, gpus = {}, {}, {}
    def idx(d, k):
        return d.setdefault(k, len(d))
    def scope_name(s):
        if s in S("Thread"):
            return None
        if s in S("CtaScope"):
            return "cta"
        if s in S("ClusterScope"):
            return "cluster"
        return "gpu" if s in parent else "sys"
    place = []
    for i, th in enumerate(threads):
        cta = parent[th]
        up = parent[cta]
        cl = up if up in S("ClusterScope") else None
        gpu = parent[cl] if cl else up
        p = f"P{i}@cta {idx(ctas, cta)}" + (f",cluster {idx(clusters, cl)}" if cl else "") + f",gpu {idx(gpus, gpu)}"
        place.append(p)
    # locations: physical ones first, then views (generic aliases)
    used = {addr[e] for e in addr}
    used |= {alias[a] for a in used if a in alias}
    names = {}
    for a in sorted(used, key=lambda a: (a in alias, a)):
        names[a] = "xyzwvu"[len(names)] if len(names) < 6 else f"m{len(names)}"
    decl = []
    for a in sorted(used, key=lambda a: (a in alias, a)):
        if space[a] not in ("Global", "Shared"):
            raise Unconvertible(f"a location in {space[a]} memory")
        if a in alias:
            decl.append(f"{names[a]} @ generic aliases {names[alias[a]]};")
        else:
            o = f" @cta {idx(ctas, owner[a])}" if space[a] == "Shared" else ""
            decl.append(f"{names[a]} = {init[a]}{o};")
    # instructions
    reads, regs, cols = [], {}, []
    rmw_w = set(rmw.values())
    for i, th in enumerate(threads):
        col, e, k = [], start[th], 0
        while e:
            sc = scope_name(scope[e])
            loc = names.get(addr.get(e))
            p = proxy.get(e)
            if e in rmw_w:
                e = po.get(e)
                continue
            if e in S("Read"):
                r = f"r{k}"
                k += 1
                regs[e] = f"P{i}:{r}"
                reads.append(e)
                if e in rmw:
                    w = rmw[e]
                    if p != "Generic" or sc is None:
                        raise Unconvertible("a weak or non-generic read-modify-write")
                    sem = {(True, True): "acq_rel", (True, False): "acquire", (False, True): "release",
                           (False, False): "relaxed"}[(e in S("Acquire"), w in S("Release"))]
                    col.append(f"atom.{sem}.{sc}.exch {r}, {loc}, {val[w]}")
                elif p == "Generic":
                    sem = "acquire" if e in S("Acquire") else "relaxed" if sc else "weak"
                    col.append(f"ld.{sem}{'.' + sc if sc else ''} {r}, {loc}")
                else:
                    op = {"Surface": "suld", "Texture": "tld", "Constant": "cold"}.get(p)
                    if op is None or sc:
                        raise Unconvertible(f"a {p} read")
                    col.append(f"{op}.weak {r}, {loc}")
            elif e in S("Write"):
                if p == "Generic":
                    sem = "release" if e in S("Release") else "relaxed" if sc else "weak"
                    col.append(f"st.{sem}{'.' + sc if sc else ''} {loc}, {val[e]}")
                elif p == "Surface" and not sc:
                    col.append(f"sust.weak {loc}, {val[e]}")
                else:
                    raise Unconvertible(f"a {p} write")
            elif e in S("Fence"):
                kind = next(k for s, k in (("FenceSC", "sc"), ("FenceAcqRel", "acq_rel"), ("FenceAcq", "acquire"),
                                           ("FenceRel", "release")) if e in S(s))
                col.append(f"fence.{kind}.{sc}")
            elif e in S("PlainProxyFence"):
                d = {t[1:] for t in F("ProxyFence", "dirs") if t[0] == e}
                other = {x for pair in d for x in pair} - {"Generic"}
                kind = {"Texture": "texture", "Surface": "surface", "Constant": "constant", "Async": "async"}.get(
                    next(iter(other), None))
                if len(other) != 1 or kind is None or any(t[0] == e for t in F("ProxyFence", "pspace")):
                    raise Unconvertible("a proxy fence")
                col.append(f"fence.proxy.{kind}")
            elif e in S("AliasFence"):
                col.append("fence.proxy.alias")
            elif e in S("BarrierArrive"):
                bid, cnt = one("BarrierArrive", "bid")[e], one("BarrierArrive", "bcount").get(e)
                if int(bid) < 0 or (cnt is not None and int(cnt) <= 0):
                    raise Unconvertible("a barrier id or count out of range")
                waits = e in one("BarrierArrive", "bwait")
                if not waits and cnt is None:
                    raise Unconvertible("bar.arrive without a count")
                col.append(f"bar.{'sync' if waits else 'arrive'} {bid}" + (f", {cnt}" if cnt else ""))
                if waits:
                    e = po.get(e)   # the wait follows directly
            elif e in S("ClusterArrive"):
                col.append("barrier.cluster.arrive" + (".relaxed" if e in S("ClusterArriveRelaxed") else ""))
            elif e in S("ClusterWait"):
                col.append("barrier.cluster.wait")
            else:
                raise Unconvertible(f"event {e}")
            e = po.get(e)
        cols.append(col)
    # the outcome: every value read, and the final value of each location whose writes coherence order ranks
    cond = [f"{regs[r]} == {val[r]}" for r in reads]
    co = set(F("Write", "co"))
    changed = True
    while changed:
        n = len(co)
        co |= {(a, d) for a, b in co for c, d in co if b == c}
        changed = len(co) != n
    phys = lambda a: alias.get(a, a)
    for a in sorted({phys(x) for x in used}):
        ws = [w for w in S("Write") if phys(addr[w]) == a]
        last = [w for w in ws if all((v, w) in co for v in ws if v != w)]
        if ws and len(last) == 1:
            cond.append(f"{names[a]} == {val[last[0]]}")
    if not any(cols):
        raise Unconvertible("no instruction in any thread")
    rows = max(len(c) for c in cols)
    width = max([len(p) for p in place] + [len(x) for c in cols for x in c]) + 1
    lines = [f"PTX {name}", f'"Generated from a counterexample of {name.split("+")[0]}."', "{", *decl, "}",
             " " + " | ".join(p.ljust(width) for p in place) + " ;"]
    for j in range(rows):
        lines.append(" " + " | ".join((c[j] if j < len(c) else "").ljust(width) for c in cols) + " ;")
    if not cond:
        raise Unconvertible("no outcome to observe")
    lines += ["exists", "(" + " /\\ ".join(cond) + ")"]
    return "\n".join(lines) + "\n"


def verdict(text: str, model_dir: Path) -> str:
    """The verdict of a litmus test (its text) under the model files in model_dir, as run_formal.py decides it."""
    t = litmus.parse(text)
    query = to_alloy87.translate(t, "gen")
    a = run_formal.Alloy6()
    base = ROOT / "build" / "mutation" / "gen" / "work"
    base.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=base) as w:
        for f in a.files:
            shutil.copyfile(model_dir / f, Path(w) / f)
        (Path(w) / "q.als").write_text(query)
        p = subprocess.run(["java", f"-Djava.io.tmpdir={w}", f"-Djava.library.path={a.native}", "-jar", str(a.jar),
                            *a.flags.split(), "-f", "-o", str(Path(w) / "out"), "q.als"], cwd=w,
                           capture_output=True, text=True, timeout=3600)
    out = p.stdout + p.stderr
    sat = {k: re.search(rf"\d+\.\s+run\s+{k}\b[^\n]*?\b(UNSAT|SAT)\b", out)
           for k in ("test", "consistent", "racy", "unconstrained")}
    if not all(sat.values()):
        return "error"
    sat = {k: m.group(1) == "SAT" for k, m in sat.items()}
    if not sat["consistent"]:
        return "forbidden (no execution)"
    return "allowed" if sat["test"] or (sat["racy"] and sat["unconstrained"]) else "forbidden"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("ids", nargs="+")
    ap.add_argument("--core", action="store_true", help="the counterexamples of mutant_equiv.py --core")
    ap.add_argument("--test", action="append", type=Path, default=[], metavar="FILE.litmus",
                    help="run this litmus test on the model and on each mutant instead (repeatable)")
    a = ap.parse_args()
    mutants = {m["id"]: m for f in ("mutants.yaml", "mutants-reword.yaml")
               for m in yaml.safe_load((MODEL / f).read_text()) or []}
    kills = 0
    base = {t: verdict(t.read_text(), MODEL) for t in a.test}
    for mid in a.ids:
        m = mutants[mid]
        work = ROOT / "build" / "mutation" / "gen" / "model" / mid
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        for f in run_formal.Alloy6.files:
            shutil.copyfile(MODEL / f, work / f)
        target = work / m.get("file", "ptx87.als")
        target.write_text(target.read_text().replace(m["find"], m["replace"], 1))
        for t in a.test:
            v1 = verdict(t.read_text(), work)
            kill = base[t] != v1 and "error" not in (base[t], v1)
            kills += kill
            print(f"{mid} {t.name}: model {base[t]}, mutant {v1}{'  KILLS' if kill else ''}", flush=True)
        if a.test:
            shutil.rmtree(work, ignore_errors=True)
            continue
        d = CEX / f"mut_{re.sub(r'[^A-Za-z0-9_]', '_', mid)}{'_core' if a.core else ''}"
        for cmd in sorted(p for p in d.iterdir() if p.is_dir() and p.name.startswith("eq_")) if d.exists() else []:
            inst = next(cmd.glob("*.txt"), None)
            if inst is None:
                continue
            try:
                text = to_litmus(instance(inst), f"{mid}+{cmd.name}")
            except Unconvertible as e:
                print(f"{mid} {cmd.name}: no litmus form ({e})", flush=True)
                continue
            out = GEN / mid / f"{cmd.name}.litmus"
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(text)
            try:
                v0, v1 = verdict(text, MODEL), verdict(text, work)
            except (to_alloy87.Unsupported, litmus.LitmusError) as e:
                print(f"{mid} {cmd.name}: the translator rejects the test ({e})", flush=True)
                continue
            kill = v0 != v1 and "error" not in (v0, v1)
            kills += kill
            print(f"{mid} {cmd.name}: model {v0}, mutant {v1}{'  KILLS' if kill else ''}", flush=True)
        shutil.rmtree(work, ignore_errors=True)
    print(f"{kills} killing tests")
    return 0


if __name__ == "__main__":
    sys.exit(main())

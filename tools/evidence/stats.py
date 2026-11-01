#!/usr/bin/env python3
"""Print the tables that summarise the H100 evidence, as Markdown. Reads only committed files; no GPU, no CUDA.

    python tools/evidence/stats.py

Tables: SASS instructions per PTX instruction, per family; hidden mechanisms and the features that show them;
scope, ordering and cache-operator encodings; special registers by source; registers per thread; goldens; the
JIT against offline SASS comparison; instruction classes and Kamui families per workload; uniform, convergence and
asynchronous traffic per workload; the Nsight Compute cross-check.
"""

from __future__ import annotations

import csv
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "catalog"))
import common  # noqa: E402

EV = ROOT / "evidence"
GOLD = ROOT / "tests" / "goldens"
HIST = EV / "histograms"
FAMILIES = common.FAMILIES
BUCKETS = [("0 (removed or folded)", lambda x: x == 0), ("up to 1", lambda x: 0 < x <= 1),
           ("1 to 2", lambda x: 1 < x <= 2), ("2 to 4", lambda x: 2 < x <= 4), ("over 4", lambda x: x > 4)]


def table(header: list[str], rows: list[list]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out) + "\n"


def read_csv(path: Path, delimiter: str = ",") -> list[dict]:
    return list(csv.DictReader((ln for ln in path.open() if not ln.startswith("#")), delimiter=delimiter))


def observations() -> list[dict]:
    return [r for r in read_csv(EV / "sass-observations.csv") if r["status"] != "pending"]


def sass_per_ptx(obs: list[dict]) -> str:
    rows = []
    sel = [r for r in obs if r["kind"] in ("instruction", "modifier") and r["sass_per_ptx"]]
    for f in FAMILIES + ["all"]:
        fr = [r for r in sel if f in ("all", r["family"])]
        if not fr:
            continue
        v = [float(r["sass_per_ptx"]) for r in fr]
        rows.append([f"`{f}`" if f != "all" else "all", len(fr), f"{statistics.median(v):.2f}",
                     *[sum(1 for x in v if test(x)) for _, test in BUCKETS],
                     sum(1 for r in fr if "software-sequence" in r["hidden_mechanism"])])
    return table(["Family", "Rows", "Median SASS per PTX", *[b for b, _ in BUCKETS], "Software sequence"], rows)


def mechanisms(obs: list[dict]) -> str:
    feats = defaultdict(list)
    for r in obs:
        for m in r["hidden_mechanism"].split(";"):
            if m and m != "none":
                feats[m].append(r["feature_id"])
    rows = []
    for m, fs in sorted(feats.items(), key=lambda kv: -len(kv[1])):
        shown = ", ".join(f"`{x}`" for x in sorted(fs)[:12]) + (f" and {len(fs) - 12} more" if len(fs) > 12 else "")
        rows.append([f"`{m}`", len(fs), shown])
    rows.append(["`none`", sum(1 for r in obs if r["hidden_mechanism"] == "none"), ""])
    return table(["Mechanism", "Rows", "Features"], rows)


def encodings(obs: list[dict]) -> str:
    keep = [r for r in obs if r["family"] == "Xkmscope" or r["feature_id"] in
            ("ld.cache_op", "st.cache_op", "ld.global.nc", "ld.volatile", "st.volatile", "membar")]
    return table(["Feature", "SASS", "Modifier encoding", "Hidden mechanism"],
                 [[f"`{r['feature_id']}`", r["sass_sequence"].replace("|", "/"), r["modifiers_encoding"],
                   r["hidden_mechanism"]] for r in sorted(keep, key=lambda r: r["feature_id"])])


def sregs(obs: list[dict]) -> str:
    rows = []
    for r in sorted((r for r in obs if r["kind"] == "special-register"), key=lambda r: r["feature_id"]):
        src = r["modifiers_encoding"].split("-> ", 1)[-1]
        kind = "constant bank 0" if "constant-bank" in r["hidden_mechanism"] and "SR_" not in src else \
            ("hardware register + constant bank" if "constant-bank" in r["hidden_mechanism"] else "hardware register")
        rows.append([f"`{r['feature_id']}`", kind, src])
    c = Counter(k for _, k, _ in rows)
    return table(["Special register", "Source", "SASS register or constant slot"], rows) + "\n" + \
        ", ".join(f"{k}: {v}" for k, v in c.most_common()) + "\n"


def registers(obs: list[dict]) -> str:
    by_entry = {}
    for r in obs:
        if r["regs"]:
            by_entry[r["entry"]] = (r["family"], int(r["regs"]))
    rows = []
    for f in FAMILIES:
        v = sorted(x for fam, x in by_entry.values() if fam == f)
        if v:
            rows.append([f"`{f}`", len(v), v[0], int(statistics.median(v)), v[-1]])
    top = sorted(by_entry.items(), key=lambda kv: -kv[1][1])[:8]
    jit = Counter()
    for eid, (_, regs) in by_entry.items():
        g = GOLD / eid / "golden.yaml"
        if g.exists():
            jr = yaml.safe_load(g.read_text()).get("jit_registers")
            jit["same" if jr == regs else "different" if jr is not None else "no JIT log"] += 1
    return table(["Family", "Entries", "Min", "Median", "Max"], rows) + "\nLargest: " + \
        ", ".join(f"`{e}` {r}" for e, (_, r) in top) + \
        f"\n\nDriver JIT against offline ptxas, registers per thread: {dict(jit)}\n"


def goldens() -> str:
    gs = [yaml.safe_load(p.read_text()) for p in sorted(GOLD.glob("*/golden.yaml"))]
    res = Counter(str(g["result"]).split()[0] for g in gs)
    det = [g for g in gs if g["deterministic"] and g["result"] == "ok"]
    unw = [(g["feature"], sum(o.get("unwritten_bytes", 0) for o in g.get("outputs", []))) for g in gs]
    san = Counter((t, "clean" if "SUMMARY: 0" in v else "reports") for g in gs for t, v in g.get("sanitizer", {}).items())
    tol = Counter(g["tolerance"].split(":")[0] for g in gs)
    rows = [["entries with a golden", len(gs)], ["results", dict(res)],
            ["deterministic entries that ran, identical in all runs",
             f"{sum(1 for g in det if g['runs_identical'])} of {len(det)}"],
            ["non-deterministic entries whose runs differed",
             f"{sum(1 for g in gs if not g['deterministic'] and not g['runs_identical'])} of {len(gs) - len(det)}"],
            ["entries with unwritten output bytes", ", ".join(f"`{f}` ({n})" for f, n in unw if n) or "none"],
            ["sanitizer", ", ".join(f"{t} {k}: {v}" for (t, k), v in sorted(san.items()))],
            ["tolerance classes", dict(tol)]]
    return table(["Quantity", "Value"], rows)


def jit() -> str:
    rows = read_csv(EV / "jit-comparison.tsv", "\t")
    c = Counter(r["match"] for r in rows)
    diff = [[f"`{r['id']}`", r["match"], r["offline_insns"], r["jit_insns"], r["first_difference"].replace("|", "/")]
            for r in rows if r["match"] != "yes"]
    return f"{len(rows)} kernels: " + ", ".join(f"{k} {v}" for k, v in c.most_common()) + "\n\n" + \
        table(["Entry", "Match", "Offline instructions", "JIT instructions", "First difference (offline / JIT)"], diff)


def classes() -> list[dict]:
    return yaml.safe_load((ROOT / "tools" / "evidence" / "opcode_classes.yaml").read_text())["classes"]


def workloads() -> dict[str, Counter]:
    out = {}
    for p in sorted(HIST.glob("*.csv")):
        if p.name == "ncu-crosscheck.csv":
            continue
        c = Counter()
        for r in read_csv(p):
            c[r["opcode_class"]] += int(r["warp_inst_executed"])
        out[p.stem] = c
    return out


def class_shares(w: dict[str, Counter]) -> str:
    names = [c["name"] for c in classes()]
    used = [n for n in names if any(c[n] for c in w.values())]
    rows = [[n, *[f"{100 * c[n] / sum(c.values()):.1f}" for c in w.values()]] for n in used]
    rows.append(["warp instructions", *[f"{sum(c.values()):,}" for c in w.values()]])
    return table(["Class (% of warp instructions)", *[f"`{k}`" for k in w]], rows)


def family_shares(w: dict[str, Counter]) -> str:
    fam_of = {c["name"]: c["families"] for c in classes()}
    rows = []
    for f in FAMILIES:
        vals = []
        for c in w.values():
            share = sum(v / len(fam_of[k]) for k, v in c.items() if f in fam_of.get(k, []))
            vals.append(f"{100 * share / sum(c.values()):.1f}")
        rows.append([f"`{f}`", *vals])
    return table(["Family (% of warp instructions)", *[f"`{k}`" for k in w]], rows) + \
        "\nA class that maps to two families counts half to each.\n"


def traffic(w: dict[str, Counter]) -> str:
    groups = {"uniform datapath (uniform ALU, uniform moves and constants)": ["uniform"],
              "convergence (BSSY, BSYNC, WARPSYNC, BAR)": ["convergence", "barrier"],
              "asynchronous machinery (TMA, mbarrier, cp.async, wgmma)": ["tma", "mbarrier", "async_copy", "wgmma"],
              "tensor cores (wgmma, mma)": ["wgmma", "mma"],
              "memory (global, shared, local, constant)": ["mem_global", "mem_shared", "mem_local", "mem_const"]}
    rows = [[g, *[f"{100 * sum(c[k] for k in ks) / sum(c.values()):.1f}" for c in w.values()]]
            for g, ks in groups.items()]
    return table(["Group (% of warp instructions)", *[f"`{k}`" for k in w]], rows)


def ncu() -> str:
    rows = read_csv(HIST / "ncu-crosscheck.csv")
    return table(["Count", "Nsight Compute metric", "ncu", "NVBit", "Difference %"],
                 [[r["count"], f"`{r['ncu_metric']}`", r["ncu"], r["nvbit"], r["difference_percent"]] for r in rows])


def main() -> int:
    obs = observations()
    w = workloads()
    parts = [("SASS instructions per PTX instruction, per family", sass_per_ptx(obs)),
             ("Hidden mechanisms", mechanisms(obs)),
             ("Scope, ordering and cache-operator encodings", encodings(obs)),
             ("Special registers by source", sregs(obs)),
             ("Registers per thread", registers(obs)),
             ("Goldens", goldens()),
             ("Driver JIT against offline ptxas", jit()),
             ("Instruction classes per workload", class_shares(w)),
             ("Kamui families per workload", family_shares(w)),
             ("Uniform, convergence and asynchronous traffic per workload", traffic(w)),
             ("Nsight Compute cross-check", ncu())]
    for title, body in parts:
        print(f"### {title}\n\n{body}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Print the summary tables of the litmus suite as Markdown.

    python tools/litmus/report_tables.py [--table NAME]

Tables (all by default): `suite` (tests per source and group), `verdicts` (results per model), `agreement`
(pairs of PTX models: tests both decide, and how many agree), `rvwmo` (the RISC-V baseline against the PTX
verdict, per shape), `families` (the verdict of every family test by scope and placement), `h100` (observed
weak outcomes per configuration against the verdict), `h100-families` (the H100 weak-outcome rate of the family
tests by scope and placement), `ptx87` (the PTX 8.7 feature tests per folder: verdicts of the PTX 8.7 model,
agreement with the verdict each test states in its comment, H100 runs), `decisions` (how many tests cite each
interpretation decision of models/ptx87/decisions.md). Reads only committed files: tests/litmus/expected.csv,
the tests, models/ptx87/decisions.md and evidence/litmus-h100/{summary,observed}.csv.
"""

from __future__ import annotations

import argparse
import csv
import itertools
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = ROOT / "tests" / "litmus" / "expected.csv"
EVID = ROOT / "evidence" / "litmus-h100"
PTX_MODELS = ["ptx-v8.7-alloy", "ptx-v7.5", "ptx-v6.0", "ptx-2019-alloy", "ptx-2019-alloy+ext", "manual-reasoning"]
SUITE = ROOT / "tests" / "litmus"
SCOPES = ["cta", "cluster", "gpu", "sys"]
PLACES = ["same-cta", "same-cluster", "diff-cluster"]


def rows(path: Path) -> list[dict]:
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def md(header: list[str], body: list[list]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in body]
    return "\n".join(out)


def by_test() -> dict[str, dict[str, str]]:
    d: dict[str, dict[str, str]] = defaultdict(dict)
    for r in rows(EXPECTED):
        d[r["test"]][r["model"]] = r["result"]
    return d


def group(tid: str) -> str:
    p = tid.split("/")
    if p[1] == "imported":
        return f"dat3m/{p[3]}" if p[2] == "dat3m" else p[2]
    return "/".join(p[1:3])


def ptx_verdict(res: dict[str, str]) -> str:
    v = {res[m] for m in PTX_MODELS if res.get(m) in ("allowed", "forbidden")}
    return v.pop() if len(v) == 1 else ("disagree" if v else "none")


def t_suite() -> str:
    c = Counter(group(t) for t in by_test())
    return md(["group", "tests"], sorted(c.items()) + [["total", sum(c.values())]])


def t_verdicts() -> str:
    c = Counter((r["model"], r["result"]) for r in rows(EXPECTED))
    models = sorted({m for m, _ in c}, key=lambda m: (PTX_MODELS + ["rvwmo"]).index(m))
    return md(["model", "allowed", "forbidden", "unknown", "error"],
              [[m] + [c[(m, k)] for k in ("allowed", "forbidden", "unknown", "error")] for m in models])


def t_agreement() -> str:
    d = by_test()
    body = []
    for a, b in itertools.combinations(PTX_MODELS, 2):
        both = [t for t, r in d.items() if r.get(a) in ("allowed", "forbidden") and r.get(b) in ("allowed", "forbidden")]
        if both:
            body.append([a, b, len(both), sum(d[t][a] == d[t][b] for t in both)])
    return md(["model A", "model B", "tests both decide", "same verdict"], body)


def shape(tid: str) -> str:
    p = tid.split("/")
    return p[3] if p[1:3] == ["kamui", "families"] else group(tid)


def t_rvwmo() -> str:
    c = Counter()
    for t, r in by_test().items():
        if r.get("rvwmo") in ("allowed", "forbidden"):
            c[(shape(t), ptx_verdict(r), r["rvwmo"])] += 1
    shapes = sorted({s for s, _, _ in c})
    body = [[s, c[(s, "forbidden", "forbidden")], c[(s, "forbidden", "allowed")], c[(s, "allowed", "allowed")],
             c[(s, "allowed", "forbidden")]] for s in shapes]
    tot = [sum(r[i] for r in body) for i in range(1, 5)]
    return md(["shape or group", "PTX forbids, RVWMO forbids", "PTX forbids, RVWMO allows (unsound)",
               "PTX allows, RVWMO allows", "PTX allows, RVWMO forbids (gap)"], body + [["total", *tot]])


def family_key(tid: str):
    name = tid.split("/")[-1]
    head, _, place = name.rpartition("+")
    base, _, scope = head.partition(".")
    return base, scope or "-", place


def grid(cell) -> str:
    fam = defaultdict(dict)
    for t in by_test():
        if "/families/" in t:
            b, s, p = family_key(t)
            fam[b][(s, p)] = cell(t)
    hdr = ["test"] + [f"{s} {p}" for s in SCOPES for p in PLACES]
    body = []
    for b in sorted(fam):
        d = fam[b]
        if ("-", "same-cta") in d:
            body.append([b] + [d.get(("-", p), "") for p in PLACES] + [""] * 9)
        else:
            body.append([b] + [d.get((s, p), "") for s in SCOPES for p in PLACES])
    return md(hdr, body)


def t_families() -> str:
    d = by_test()
    return ("A = allowed, F = forbidden (all PTX models agree). Weak tests have no scope; their three columns are"
            " the three placements.\n\n" + grid(lambda t: ptx_verdict(d[t])[0].upper()))


def t_h100() -> str:
    if not (EVID / "summary.csv").exists():
        return "(no H100 results)"
    s = rows(EVID / "summary.csv")
    body = []
    for cfg in sorted({r["config"] for r in s}):
        rs = [r for r in s if r["config"] == cfg]
        c = Counter(r["status"] for r in rs)
        body.append([cfg, len(rs), sum(int(r["instances"]) for r in rs), c["weak-seen"], c["weak-unseen"], c["ok"],
                     c["forbidden-observed"]])
    return md(["config", "tests", "instances", "allowed and seen", "allowed, never seen", "forbidden, never seen",
               "forbidden but seen"], body)


def t_h100_families() -> str:
    if not (EVID / "summary.csv").exists():
        return "(no H100 results)"
    best: dict[str, float] = defaultdict(float)
    for r in rows(EVID / "summary.csv"):
        best[r["test"]] = max(best[r["test"]], float(r["rate"]))
    d = by_test()

    def cell(t):
        v = ptx_verdict(d[t])[0].upper()
        return f"{v} {best[t]:.0e}" if best.get(t) else f"{v} 0"
    return ("Verdict and the highest weak-outcome rate over the three configurations (weak instances / instances)."
            "\n\n" + grid(cell))


def t_ptx87() -> str:
    import re
    d = by_test()
    summ = defaultdict(list)
    for r in rows(EVID / "summary.csv"):
        summ[r["test"]].append(r["status"])
    c = defaultdict(Counter)
    for p in sorted((SUITE / "ptx" / "kamui" / "ptx87").rglob("*.litmus")):
        tid = p.relative_to(SUITE).with_suffix("").as_posix()
        g = tid.split("/")[3]
        res = d.get(tid, {}).get("ptx-v8.7-alloy", "none")
        m = re.search(r"Expected: (allowed|forbidden)", p.read_text())
        c[g]["tests"] += 1
        c[g][res] += 1
        c[g]["as stated"] += bool(m and m.group(1) == res)
        if summ.get(tid):
            c[g]["on H100"] += 1
            c[g]["forbidden but seen"] += "forbidden-observed" in summ[tid]
    cols = ["tests", "allowed", "forbidden", "as stated", "on H100", "forbidden but seen"]
    body = [[g] + [c[g][k] for k in cols] for g in sorted(c)]
    tot = [sum(r[i + 1] for r in body) for i in range(len(cols))]
    return md(["folder"] + cols, body + [["total", *tot]])


def t_decisions() -> str:
    """For each decision: the litmus tests its `Tests:` line names (paths or patterns under tests/litmus/ptx/)."""
    import fnmatch
    import re
    text = (ROOT / "models" / "ptx87" / "decisions.md").read_text()
    ids = sorted(p.relative_to(SUITE / "ptx").with_suffix("").as_posix() for p in (SUITE / "ptx").rglob("*.litmus"))
    body = []
    for m in re.finditer(r"^### (D\d+)\. (.+?)$(.*?)(?=^### |\Z)", text, re.M | re.S):
        dn, title, sec = m.groups()
        t = re.search(r"Tests?:(.*?)(?:\n\n|\Z)", sec, re.S)
        toks = re.findall(r"`([^`]+)`", t.group(1)) if t else []
        hit, folder = set(), None
        for pat in toks:
            pat = pat.removeprefix("tests/litmus/ptx/")
            if "/" in pat:
                folder = pat.rsplit("/", 1)[0]
            elif folder:  # a bare name: in the folder of the path before it
                pat = f"{folder}/{pat}"
            else:
                continue
            hit |= {i for i in ids if fnmatch.fnmatch(i, pat) or fnmatch.fnmatch(i, pat + "*")}
        body.append([dn, title, len(hit)])
    body.sort(key=lambda r: int(r[0][1:]))
    return md(["decision", "title", "tests named"], body)


TABLES = {"suite": t_suite, "verdicts": t_verdicts, "agreement": t_agreement, "rvwmo": t_rvwmo, "ptx87": t_ptx87, "decisions": t_decisions,
          "families": t_families, "h100": t_h100, "h100-families": t_h100_families}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--table", choices=list(TABLES))
    a = ap.parse_args()
    for name, fn in TABLES.items():
        if a.table in (None, name):
            print(f"### {name}\n\n{fn()}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

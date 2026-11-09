#!/usr/bin/env python3
"""Check Ptx87.v against the Alloy model on every execution of the litmus tests.

For each test of tests/litmus/expected.csv run by an Alloy model of PTX 8.7 (`ptx-v8.7-alloy`, `kamui-alloy`,
`kamui-std-alloy`), Alloy enumerates the test's executions (AlloyDump.java, through dump.sh) and the checker
extracted from Rocq (build/rocq/src/checker) evaluates each one. Two things must hold:

1. On every execution, the checker agrees with Alloy: well-formed (always, since Alloy only finds executions that
   satisfy the facts), each axiom, the model, undefined behaviour, the mixed-size race, and every tuple of the
   derived relations and sets that FORMAT.md lists.
2. The verdict computed from the checker's answers is the verdict of expected.csv for that model.

Which executions: a test with no mbarrier and no access granule (`Mbar = none`, `Access = none`) can have neither
undefined behaviour nor a mixed-size race, so its verdict only needs the executions with the outcome (the query's
`unconstrained` command: the facts and the outcome); its verdict is `allowed` exactly when one of them satisfies the
model. Any other test needs all executions (the facts alone, `--all`), and its verdict follows run_formal.py's rule:
some execution satisfies the model and has the outcome or undefined behaviour, or some execution satisfies the model
and has a mixed-size race and some execution has the outcome (decision D38). A test whose query states undefined behaviour of the program
itself (`run test { ptx_mm }`, decision D39) is allowed exactly when some execution satisfies the model.

A test with more than --max executions of the facts is enumerated again, with only the executions that have the
outcome, undefined behaviour or a mixed-size race (a copy of the query with that run command, in
build/rocq-extract/litmus/queries/). The verdict rule looks only at those executions, so the verdict is the same.

Run in the dev container after `make -C proofs/rocq checker`:

    tools/dev.sh 'proofs/rocq/extract/litmus.py --jobs 24'                  # every test, all three models
    tools/dev.sh 'proofs/rocq/extract/litmus.py --model kamui-alloy mp'     # tests whose name contains "mp"
    tools/dev.sh 'proofs/rocq/extract/litmus.py --max 20000 --jobs 24'

Results: build/rocq-extract/litmus/results.csv (one row per test and model) and, for each disagreement, the dump
and the checker's answers in build/rocq-extract/litmus/fail/. Exit status 1 if any execution or verdict disagrees,
or if a test was cut at --max (its verdict is then not checked).
"""
import argparse
import csv
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "tools" / "litmus"))
import to_alloy87  # noqa: E402
import to_kamui  # noqa: E402

MODELS = ("ptx-v8.7-alloy", "kamui-alloy", "kamui-std-alloy")
PREDS = ("coherence", "fence_sc", "atomicity", "no_thin_air", "sc_per_location", "causality", "ptx_mm",
         "mb_undefined", "undefined", "mixed_size_race")
CHECKER = ROOT / "build" / "rocq" / "src" / "checker"
OUT = ROOT / "build" / "rocq-extract" / "litmus"


def query(tid, model):
    if model == "ptx-v8.7-alloy":
        return to_alloy87.als_path(tid)
    return to_kamui.kamui_query_for(tid, model)


def parse(text, prefix):
    """Blocks of a dump or of the checker's answers: name -> (preds, set of rel/set tuples)."""
    out, cur = {}, None
    for line in text.splitlines():
        w = line.split()
        if not w:
            continue
        if w[0] == "instance":
            cur = (" ".join(w[1:]), {}, set())
        elif w[0] == "end":
            out[cur[0]] = (cur[1], cur[2])
            cur = None
        elif w[0] == prefix:
            cur[1][w[1]] = w[2] == "1"
        elif w[0] in (prefix + "rel", prefix + "set"):
            cur[2].add(tuple(w[1:]))
    return out


def verdict(answers, alloy, outcome_mode, static_ub):
    if outcome_mode or static_ub:
        return "allowed" if any(a[0]["ptx_mm"] for a in answers.values()) else "forbidden"
    sat = lambda f: any(f(a[0], alloy[k][0]) for k, a in answers.items())  # noqa: E731
    test = sat(lambda r, al: r["ptx_mm"] and (al["outcome"] or r["undefined"]))
    racy = sat(lambda r, al: r["ptx_mm"] and r["mixed_size_race"])
    unconstrained = sat(lambda r, al: al["outcome"])
    return "allowed" if test or (racy and unconstrained) else "forbidden"


def run(tid, model, expected, args):
    q = query(tid, model)
    if q is None or not q.exists():
        return dict(test=tid, model=model, status="no query")
    text = q.read_text()
    static_ub = bool(re.search(r"^run test \{ ptx_mm \}", text, re.M))
    outcome_mode = not static_ub and bool(re.search(r"^\s*Mbar = none", text, re.M)
                                          and re.search(r"^\s*Access = none", text, re.M))
    cmd = [str(HERE / "dump.sh"), "--max", str(args.max)] + (["--cmd", "unconstrained"] if outcome_mode else ["--all"])
    t0 = time.time()
    d = subprocess.run(cmd + [str(q)], capture_output=True, text=True)
    mode = "outcome" if outcome_mode else "all"
    if d.returncode == 3 and not outcome_mode and not static_ub:
        scope = re.search(r"^run unconstrained \{ outcome \} (for .*?)\s*(//.*)?$", text, re.M).group(1)
        cq = OUT / "queries" / model / (tid.replace("/", "__") + ".als")
        cq.parent.mkdir(parents=True, exist_ok=True)
        cq.write_text(text + f"\nrun candidates {{ outcome or undefined or mixed_size_race }} {scope}\n")
        d = subprocess.run([str(HERE / "dump.sh"), "--max", str(args.max), "--cmd", "candidates", str(cq)],
                           capture_output=True, text=True)
        mode = "candidates"
    if d.returncode not in (0, 3):
        return dict(test=tid, model=model, status="dump error", detail=d.stderr.strip()[-300:])
    truncated = d.returncode == 3
    c = subprocess.run([str(CHECKER)], input=d.stdout, capture_output=True, text=True)
    if c.returncode != 0:
        return dict(test=tid, model=model, status="checker error", detail=c.stderr.strip()[-300:])
    alloy, rocq = parse(d.stdout, "alloy"), parse(c.stdout, "rocq")
    bad = []
    for k, (ap, at) in alloy.items():
        rp, rt = rocq[k]
        if not rp["wf"]:
            bad.append(f"{k}: not wf (prog {int(rp['wf_prog'])}, exec {int(rp['wf_exec'])})")
        bad += [f"{k}: {p} alloy {int(ap[p])} rocq {int(rp[p])}" for p in PREDS if ap.get(p) != rp[p]]
        diff = at ^ rt
        if diff:
            bad.append(f"{k}: {len(diff)} tuples differ, e.g. {sorted(diff)[:3]}")
    v = verdict(rocq, alloy, outcome_mode, static_ub)
    status = "ok"
    if bad:
        status = "disagree"
    elif truncated:
        status = "truncated"
    elif v != expected:
        status = "wrong verdict"
    if status != "ok":
        f = OUT / "fail" / model / tid.replace("/", "__")
        f.mkdir(parents=True, exist_ok=True)
        (f / "dump.txt").write_text(d.stdout)
        (f / "answers.txt").write_text(c.stdout)
        (f / "problems.txt").write_text("\n".join(bad) + "\n")
    return dict(test=tid, model=model, status=status, mode=mode,
                instances=len(alloy), verdict=v, expected=expected, seconds=round(time.time() - t0, 1),
                detail="; ".join(bad[:3]))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("filter", nargs="*", help="only tests whose name contains one of these strings")
    ap.add_argument("--model", choices=MODELS + ("all",), default="all")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--max", type=int, default=3000, help="instances per test at most (default 3000)")
    args = ap.parse_args()
    if not CHECKER.exists():
        sys.exit("no checker: run make -C proofs/rocq checker first")
    models = MODELS if args.model == "all" else (args.model,)
    rows = [r for r in csv.DictReader(open(ROOT / "tests" / "litmus" / "expected.csv"))
            if r["model"] in models and (not args.filter or any(s in r["test"] for s in args.filter))]
    OUT.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(args.jobs) as ex:
        res = list(ex.map(lambda r: run(r["test"], r["model"], r["result"], args), rows))
    fields = ["test", "model", "status", "mode", "instances", "verdict", "expected", "seconds", "detail"]
    with open(OUT / "results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fields)
        w.writeheader()
        w.writerows(res)
    counts = {}
    for r in res:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(f"{len(res)} test runs: " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
    print(f"executions checked: {sum(r.get('instances', 0) for r in res)}")
    for r in res:
        if r["status"] != "ok":
            print(f"{r['status']}: {r['model']} {r['test']} {r.get('detail', '')}")
    sys.exit(0 if counts.get("ok", 0) == len(res) else 1)


if __name__ == "__main__":
    main()

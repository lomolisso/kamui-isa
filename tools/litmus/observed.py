#!/usr/bin/env python3
"""Turn the H100 litmus results into evidence/litmus-h100/observed.csv and compare them with the formal verdicts.

    python tools/litmus/observed.py --write    # rebuild observed.csv and summary.csv from results/
    python tools/litmus/observed.py            # check: both files are current; list forbidden outcomes observed

Input: evidence/litmus-h100/results/<test path>/<config>.json (tools/litmus/runner, via run_h100.py) and
tests/litmus/h100/<test path>/spec.txt (which register or location each value is). Each distinct final state
becomes one row of observed.csv:

| Column | Meaning |
|---|---|
| test | the test id |
| config | plain, stress or shuffle (see tools/litmus/runner/litmus_runner.c) |
| class | where the instance's threads actually ran: same-sm, same-cluster (one cluster, several SMs), diff-cluster |
| outcome | the final state, e.g. `P1:r0=1 P1:r1=0` |
| count | how many instances ended in that state |
| total | instances of this test, configuration and class |
| observed_weak | yes if the outcome satisfies the test's condition (the outcome the test asks about) |
| model_verdict | the formal verdict for the condition: allowed or forbidden (see `verdict` below), or unknown |

summary.csv has one row per (test, config): `instances`, `weak` (instances whose outcome satisfies the
condition), `rate`, `verdict`, and `status`: `ok`, `weak-seen` (allowed and observed), `weak-unseen` (allowed, never
observed) or `forbidden-observed` (a finding that must be investigated).

The verdict of a test is the one its formal models agree on in tests/litmus/expected.csv (the PTX models, not
the RVWMO baseline); for a test with only a hand-reasoned verdict, that one.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import litmus  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "tests" / "litmus"
EVID = ROOT / "evidence" / "litmus-h100"
RESULTS = EVID / "results"
OBS_FIELDS = ["test", "config", "class", "outcome", "count", "total", "observed_weak", "model_verdict"]
SUM_FIELDS = ["test", "config", "instances", "weak", "rate", "verdict", "status"]
PTX_MODELS = {"ptx-v7.5", "ptx-v6.0", "ptx-2019-alloy", "ptx-2019-alloy+ext", "manual-reasoning"}


def verdicts(expected: Path = SUITE / "expected.csv") -> dict[str, str]:
    by: dict[str, set[str]] = defaultdict(set)
    with open(expected, newline="") as f:
        for r in csv.DictReader(f):
            if r["model"] in PTX_MODELS and r["result"] in ("allowed", "forbidden"):
                by[r["test"]].add(r["result"])
    return {t: (v.pop() if len(v) == 1 else "unknown") for t, v in by.items()}


def read_spec(path: Path) -> list[str]:
    names = {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] in ("reg", "gloc"):
            names[(parts[0], int(parts[1]))] = parts[2]
    regs = [names[k] for k in sorted(k for k in names if k[0] == "reg")]
    glocs = [names[k] for k in sorted(k for k in names if k[0] == "gloc")]
    return regs + glocs


def build(results: Path = RESULTS) -> tuple[str, str]:
    ver = verdicts()
    obs, summ = [], []
    for res in sorted(results.rglob("*.json")):
        rel = res.parent.relative_to(results).as_posix()
        tid, config = f"ptx/{rel}", res.stem
        t = litmus.load(SUITE / f"{tid}.litmus")
        names = read_spec(SUITE / "h100" / rel / "spec.txt")
        data = json.loads(res.read_text())
        totals: dict[str, int] = defaultdict(int)
        for h in data["histogram"]:
            totals[h["class"]] += h["count"]
        weak = 0
        v = ver.get(tid, "unknown")
        for h in sorted(data["histogram"], key=lambda h: (h["class"], h["values"])):
            env = dict(zip(names, h["values"]))
            hit = litmus.evaluate(t.condition, env)
            weak += h["count"] if hit else 0
            obs.append({"test": tid, "config": config, "class": h["class"],
                        "outcome": " ".join(f"{n}={x}" for n, x in env.items()), "count": h["count"],
                        "total": totals[h["class"]], "observed_weak": "yes" if hit else "no", "model_verdict": v})
        n = data["instances"]
        status = ("forbidden-observed" if weak and v == "forbidden" else "weak-seen" if weak
                  else "weak-unseen" if v == "allowed" else "ok")
        summ.append({"test": tid, "config": config, "instances": n, "weak": weak, "rate": f"{weak / n:.3g}",
                     "verdict": v, "status": status})
    return _csv(obs, OBS_FIELDS), _csv(summ, SUM_FIELDS)


def _csv(rows, fields) -> str:
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=fields, lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
    return buf.getvalue()


def forbidden_observed(summary_text: str) -> list[dict]:
    return [r for r in csv.DictReader(io.StringIO(summary_text)) if r["status"] == "forbidden-observed"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args()
    if not RESULTS.exists():
        print("no H100 results yet")
        return 0
    obs, summ = build()
    if a.write:
        (EVID / "observed.csv").write_text(obs)
        (EVID / "summary.csv").write_text(summ)
    else:
        stale = [p for p, s in ((EVID / "observed.csv", obs), (EVID / "summary.csv", summ))
                 if not p.exists() or p.read_text() != s]
        for p in stale:
            print(f"stale: {p.relative_to(ROOT)} (run tools/litmus/observed.py --write)")
        if stale:
            return 1
    bad = forbidden_observed(summ)
    for r in bad:
        print(f"forbidden outcome observed: {r['test']} [{r['config']}] {r['weak']} of {r['instances']}")
    print(f"{len(list(csv.DictReader(io.StringIO(summ))))} test runs, {len(bad)} with a forbidden outcome observed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

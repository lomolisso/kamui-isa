#!/usr/bin/env python3
"""The test scorecard of the PTX 8.7 models: for every feature of models/ptx87/coverage.yaml, how well the litmus
suite exercises it, and whether it meets the bar below.

    python tools/litmus/scorecard.py            # print the scorecard
    python tools/litmus/scorecard.py --write    # write models/ptx87/scorecard.md
    python tools/litmus/scorecard.py --check    # fail if scorecard.md is stale
    python tools/litmus/scorecard.py --bar      # list every feature below the bar (exit 1 if any)

The bar (a feature that does not meet it is under-tested):
- at least MIN_TESTS tests use it;
- among them, the PTX 8.7 models give both verdicts (some outcome allowed, some forbidden);
- it is used with every scope, state space and placement where it is valid (features.valid_scopes,
  valid_spaces, required_placements);
- at least one mutant of models/ptx87/mutants.yaml is killed by a test that uses it, when a mutant names a rule
  of the feature (mutation.csv);
- exceptions, each with its reason, are in BAR_EXCEPTIONS.
Register-only features (no memory event, no litmus form) are exempt.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import features as F  # noqa: E402

ROOT = HERE.parent.parent
OUT = ROOT / "models" / "ptx87" / "scorecard.md"
EXPECTED = ROOT / "tests" / "litmus" / "expected.csv"
H100 = ROOT / "evidence" / "litmus-h100" / "summary.csv"
MUTATION = ROOT / "models" / "ptx87" / "mutation.csv"
MIN_TESTS = 8
NVIDIA_MODELS = ("ptx-v7.5", "ptx-v6.0", "ptx-2019-alloy")
CROSSCHECK = {"ptx/kamui/ptx87/ld-st/MP+ldu", "ptx/kamui/ptx87/mbarrier-init/mbarrier-init+inval+use",
              "ptx/kamui/ptx87/mbarrier-init/mbarrier-init+no-fence+cluster-barrier",
              "ptx/kamui/ptx87/sizes/mixed-size+flag", "ptx/kamui/ptx87/sizes/mixed-size+race",
              "ptx/kamui/ptx87/tensormap/MP+tensormap+no-release-proxy-fence"}
# feature -> why it cannot meet a part of the bar ("verdicts", "tests", ...: the part it is excused from)
BAR_EXCEPTIONS: dict[str, dict[str, str]] = {
    "bar.red": dict.fromkeys(("tests", "verdicts", "placements"),
                             "the reduction result of bar.red is modelled by neither model (D9); its synchronization is "
                             "that of bar.sync, which the bar.sync tests cover"),
    "mbarrier.pending_count": dict.fromkeys(("tests", "verdicts", "scopes", "placements"),
                                            "reads a state token held in a register, not memory: no memory event (D27)"),
    "st.param": dict.fromkeys(("tests", "verdicts"),
                              "a kernel's parameters are read-only; st.param writes the parameters of a called function, "
                              "which a litmus test has none of"),
}


def required_placements(fid: str) -> tuple:
    if fid.startswith(("bar.", "barrier.sync")):
        return ("same-cta",)
    if fid.startswith(("mbarrier.", "barrier.cluster", "fence.sync_restrict", "fence.op_restrict")) or \
            "shared" in fid:
        return ("same-cta", "same-cluster")
    if F.valid_scopes(fid):
        return ("same-cta", "same-cluster", "diff-cluster")
    return ()


def load_verdicts() -> dict[str, dict[str, str]]:
    v = defaultdict(dict)
    with open(EXPECTED, newline="") as f:
        for r in csv.DictReader(f):
            v[r["test"]][r["model"]] = r["result"]
    return v


def load_h100() -> tuple[set, set]:
    ran, weak = set(), set()
    if H100.exists():
        with open(H100, newline="") as f:
            for r in csv.DictReader(f):
                ran.add(r["test"])
                if int(r["weak"] or 0):
                    weak.add(r["test"])
    return ran, weak


def load_mutants() -> list[dict]:
    if not MUTATION.exists():
        return []
    with open(MUTATION, newline="") as f:
        return list(csv.DictReader(f))


def row(f: F.Feature, v, ran, weak, mutants) -> dict:
    ts = f.tests
    ptx = [v[t].get("ptx-v8.7-alloy") or v[t].get("ptx-v8.7") for t in ts]
    both = [t for t in ts if "ptx-v8.7-alloy" in v[t] and "ptx-v8.7" in v[t]]
    killed = sorted({m["id"] for m in mutants if m["status"] == "killed"
                     and set(m["killers"].split(";")) & set(ts)})
    return {
        "tests": len(ts), "both": len(both),
        "allowed": ptx.count("allowed"), "forbidden": ptx.count("forbidden"),
        "scopes": sorted(f.scopes), "spaces": sorted(f.spaces), "placements": sorted(f.placements),
        "h100": sum(t in ran for t in ts), "weak": sum(t in weak for t in ts),
        "crosscheck": sum(t in CROSSCHECK for t in ts),
        "nvidia": sum(any(v[t].get(m) in ("allowed", "forbidden") for m in NVIDIA_MODELS) for t in ts),
        "decisions": sorted(set(re.findall(r"D\d+", f.how)), key=lambda d: int(d[1:])),
        "mutants": killed,
    }


def bar(f: F.Feature, r: dict) -> list[str]:
    """The parts of the bar the feature misses."""
    if f.exempt:
        return []
    exc = BAR_EXCEPTIONS.get(f.id, {})
    miss = []
    if r["tests"] < MIN_TESTS and "tests" not in exc:
        miss.append(f"{r['tests']} tests (< {MIN_TESTS})")
    if not (r["allowed"] and r["forbidden"]) and "verdicts" not in exc:
        miss.append("one verdict only" if r["tests"] else "no verdict")
    sc = [s for s in F.valid_scopes(f.id) if s not in f.scopes and not (s == "gpu" and "default" in f.scopes)]
    if sc and "scopes" not in exc:
        miss.append("scopes " + ",".join(sc))
    sp = [s for s in F.valid_spaces(f.id) if s not in f.spaces]
    if sp and "spaces" not in exc:
        miss.append("spaces " + ",".join(sp))
    pl = [p for p in required_placements(f.id) if p not in f.placements]
    if pl and "placements" not in exc:
        miss.append("placements " + ",".join(pl))
    return miss


def group(fid: str) -> str:
    if fid in F.REGISTER_ONLY:
        return "register (exempt)"
    head = fid.split(".")[0]
    return {"red": "atom", "membar": "fence", "ldu": "ld", "barrier": "bar", "cp": "async", "st": "ld",
            "prefetch": "hints", "prefetchu": "hints", "applypriority": "hints", "createpolicy": "hints",
            "discard": "ld", "ldmatrix": "wgmma", "stmatrix": "wgmma", "tensormap": "async"}.get(head, head)


def build() -> tuple[list[F.Feature], dict, dict]:
    fs = F.features()
    v = load_verdicts()
    ran, weak = load_h100()
    mutants = load_mutants()
    rows = {f.id: row(f, v, ran, weak, mutants) for f in fs}
    misses = {f.id: bar(f, rows[f.id]) for f in fs}
    return fs, rows, misses


def markdown(fs, rows, misses) -> str:
    out = ["# Test scorecard of the PTX 8.7 models", "",
           "Generated by `tools/litmus/scorecard.py --write`; do not edit by hand. One row per feature of "
           "`coverage.yaml`. A test *uses* a feature when one of its instructions matches the feature "
           "(`tools/litmus/features.py`).", "",
           "Columns: **tests** using the feature; **both** decided by both PTX 8.7 models; **A/F** tests whose "
           "condition is allowed / forbidden; **scopes**, **spaces**, **placements** the feature is used with "
           "(`shared::cluster-remote` is distributed shared memory: another CTA's shared memory); **H100** tests "
           "run on the H100 (**weak**: the condition's outcome was seen); **x-check** tests whose verdict was "
           "settled by a decision after the two models first disagreed; **NVIDIA** tests that a model written "
           "by NVIDIA researchers also decides (PTX 6.0, PTX 7.5, 2019 Alloy); **mutants** killed by these "
           "tests (`mutation.md`); **bar**: what the feature misses of the bar in `scorecard.py` (empty: met).",
           ""]
    by_group = defaultdict(list)
    for f in fs:
        by_group[group(f.id)].append(f)
    out += ["## Summary per group", "", "| Group | Features | Exempt | Meet the bar | Tests (median) |",
            "|---|---|---|---|---|"]
    for g, gf in sorted(by_group.items()):
        live = [f for f in gf if not f.exempt]
        ok = sum(not misses[f.id] for f in live)
        med = sorted(rows[f.id]["tests"] for f in live)[len(live) // 2] if live else 0
        out.append(f"| {g} | {len(gf)} | {len(gf) - len(live)} | {ok} of {len(live)} | {med} |")
    total = [f for f in fs if not f.exempt]
    out += ["", f"Total: {sum(not misses[f.id] for f in total)} of {len(total)} features meet the bar; "
            f"{len(fs) - len(total)} register-only features are exempt.", "",
            "## Features", "",
            "| Feature | Tests | Both | A/F | Scopes | Spaces | Placements | H100 (weak) | x-check | NVIDIA | "
            "Decisions | Mutants | Bar |", "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for f in fs:
        if f.exempt:
            continue
        r = rows[f.id]
        out.append(f"| `{f.id}` | {r['tests']} | {r['both']} | {r['allowed']}/{r['forbidden']} | "
                   f"{' '.join(r['scopes'])} | {' '.join(r['spaces'])} | {' '.join(r['placements'])} | "
                   f"{r['h100']} ({r['weak']}) | {r['crosscheck']} | {r['nvidia']} | {' '.join(r['decisions'])} | "
                   f"{len(r['mutants'])} | {'; '.join(misses[f.id])} |")
    out += ["", "## Exempt (register operations)", "",
            ", ".join(f"`{f.id}`" for f in fs if f.exempt), ""]
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--bar", action="store_true")
    a = ap.parse_args()
    fs, rows, misses = build()
    text = markdown(fs, rows, misses)
    if a.write:
        OUT.write_text(text)
        print(f"wrote {OUT.relative_to(ROOT)}")
    elif a.check:
        if not OUT.exists() or OUT.read_text() != text:
            print("models/ptx87/scorecard.md is stale: run tools/litmus/scorecard.py --write", file=sys.stderr)
            return 1
        print("scorecard.md is current")
    elif a.bar:
        bad = [(f.id, misses[f.id]) for f in fs if misses[f.id]]
        for fid, m in bad:
            print(f"{fid}: {'; '.join(m)}")
        print(f"{len(bad)} features below the bar")
        return 1 if bad else 0
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

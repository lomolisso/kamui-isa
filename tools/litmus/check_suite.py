#!/usr/bin/env python3
"""Check the litmus suite and tests/litmus/expected.csv. Needs no Java or GPU, so it also runs in CI.

    python tools/litmus/check_suite.py            # all checks; exit 1 on a failure
    python tools/litmus/check_suite.py --list     # also print every disagreement, explained or not

Checks:
1. Every `.litmus` file under tests/litmus/ptx/ parses and its condition is an `exists` condition.
2. tests/litmus/ptx/imported/origin.csv lists exactly the imported tests.
3. expected.csv: known columns, known results, no duplicate (test, model, tool) row, no row for a missing test,
   every test Dartagnan can parse (no `.cluster` scope, no PTX 8.6 fence) has a `ptx-v7.5` row, every test
   tools/litmus/to_alloy87.py can express has a `ptx-v8.7-alloy` row, and every other test has at least one row.
   Once expected.csv has any `ptx-v8.7` row (the Dartagnan fork), every test with a `ptx-v8.7-alloy` row needs
   one too.
   A `ptx-v8.7-alloy` row whose flags say `(no execution)` (the program has no execution at all, for example a
   barrier that never completes) must be explained (kind `no-execution`).
4. Agreement: an imported test's `ptx-v7.5` and `ptx-v6.0` results equal the upstream verdicts in origin.csv
   (Dat3M's expected CSVs, or the permit/assert annotation of a mixedproxy test); results of different PTX models
   for the same test agree; no result is `unknown` or `error`.
5. Lowering: when the PTX models forbid an outcome, the naive RVWMO lowering (`rvwmo`) forbids it too.
6. Hardware: no outcome observed on the H100 (evidence/litmus-h100/summary.csv) is forbidden by any PTX model,
   unless the allow-list explains it (kind `h100`, model = the run configuration).
7. Coverage: every feature of tests/corpus/catalog.yaml in the memory-related sections has a row in
   models/ptx87/coverage.yaml, and every row names a known feature; every modelled feature has a `kamui` field
   with the lowering rules that models/kamui/lowering.yaml gives it.
8. Kamui: models/kamui/kamui.als is models/ptx87/ptx87.als below the `module` line (the Kamui model is the PTX 8.7
   model); every lowered test (tests/litmus/alloy-kamui/) has its `kamui-alloy` / `kamui-std-alloy` row; no
   lowered test allows an outcome that the PTX models forbid (kind `kamui`); every hand-written Kamui test
   (tests/litmus/kamui-isa/hand/) gets the verdict its description ends with. `--stronger` lists the tests where
   the lowered program forbids an outcome PTX allows (Kamui may be stronger than PTX).
Every exception to check 4 must be listed in tests/litmus/allowlist.yaml with a reason. An allow-list entry that
no longer matches anything is also an error, so the list stays current.
"""

from __future__ import annotations

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import litmus  # noqa: E402
import to_alloy87  # noqa: E402
import to_kamui  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "tests" / "litmus"
EXPECTED = SUITE / "expected.csv"
ORIGIN = SUITE / "ptx" / "imported" / "origin.csv"
ALLOWLIST = SUITE / "allowlist.yaml"
FIELDS = ["test", "source", "condition", "model", "model_version", "tool", "tool_version", "flags", "result",
          "runtime_s"]
RESULTS = {"allowed", "forbidden", "unknown", "error"}
KAMUI_MODELS = {"kamui-alloy", "kamui-std-alloy"}
BASELINES = {"rvwmo"} | KAMUI_MODELS  # models of a lowered program, not of the PTX test itself
UPSTREAM_COLUMN = {"ptx-v7.5": "upstream_ptx_v7_5", "ptx-v6.0": "upstream_ptx_v6_0"}


def read_csv(path: Path) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def test_id(path: Path) -> str:
    return path.relative_to(SUITE).with_suffix("").as_posix()


def findings(suite: Path = SUITE) -> tuple[list[str], list[tuple[str, str, str, str]]]:
    """Return (hard errors, disagreements). A disagreement is (kind, test, model, detail)."""
    errors: list[str] = []
    tests: dict[str, litmus.Litmus] = {}
    for p in sorted((suite / "ptx").rglob("*.litmus")):
        tid = p.relative_to(suite).with_suffix("").as_posix()
        try:
            t = litmus.load(p)
        except litmus.LitmusError as e:
            errors.append(f"parse: {e}")
            continue
        if t.quantifier != "exists":
            errors.append(f"{tid}: condition is '{t.quantifier}', not 'exists'")
        tests[tid] = t
    hand: dict[str, litmus.Litmus] = {}
    for p in sorted((suite / "kamui-isa" / "hand").rglob("*.litmus")):
        tid = p.relative_to(suite).with_suffix("").as_posix()
        try:
            hand[tid] = litmus.load(p)
        except litmus.LitmusError as e:
            errors.append(f"parse: {e}")

    origin = {r["test"]: r for r in read_csv(suite / "ptx" / "imported" / "origin.csv")}
    imported = {tid for tid in tests if tid.startswith("ptx/imported/")}
    for tid in sorted(imported - set(origin)):
        errors.append(f"{tid}: imported test missing from origin.csv")
    for tid in sorted(set(origin) - imported):
        errors.append(f"{tid}: in origin.csv but no file")

    rows = read_csv(suite / "expected.csv")
    if rows and list(rows[0].keys()) != FIELDS:
        errors.append(f"expected.csv columns are {list(rows[0].keys())}, expected {FIELDS}")
    seen = set()
    by_test: dict[str, dict[str, str]] = defaultdict(dict)
    no_exec: set[str] = set()
    for r in rows:
        if r["model"] == to_alloy87.MODEL_NAME and "(no execution)" in r["flags"]:
            no_exec.add(r["test"])
        key = (r["test"], r["model"], r["tool"])
        if key in seen:
            errors.append(f"expected.csv: duplicate row {key}")
        seen.add(key)
        if r["test"] not in tests and r["test"] not in hand:
            errors.append(f"expected.csv: row for missing test {r['test']}")
        if r["result"] not in RESULTS:
            errors.append(f"expected.csv: bad result {r['result']!r} for {key}")
        by_test[r["test"]][r["model"]] = r["result"]
    fork_rows = any("ptx-v8.7" in m for m in by_test.values())
    for tid, t in tests.items():
        if fork_rows and to_alloy87.MODEL_NAME in by_test.get(tid, {}) and "ptx-v8.7" not in by_test[tid]:
            errors.append(f"{tid}: no ptx-v8.7 row in expected.csv")
        if t.dartagnan_ok and "ptx-v7.5" not in by_test.get(tid, {}):
            errors.append(f"{tid}: no ptx-v7.5 row in expected.csv")
        if not by_test.get(tid):
            errors.append(f"{tid}: no verdict in expected.csv")
        if to_alloy87.MODEL_NAME not in by_test.get(tid, {}):
            try:
                to_alloy87.translate(t, tid)
            except to_alloy87.Unsupported:
                pass
            else:
                errors.append(f"{tid}: no {to_alloy87.MODEL_NAME} row in expected.csv")

    dis: list[tuple[str, str, str, str]] = []
    for tid in sorted(no_exec):
        dis.append(("no-execution", tid, to_alloy87.MODEL_NAME, "the program has no execution"))
    for tid, res in sorted(by_test.items()):
        for model, result in res.items():
            if result in ("unknown", "error"):
                dis.append((result, tid, model, result))
            col = UPSTREAM_COLUMN.get(model)
            up = origin.get(tid, {}).get(col, "") if col else ""
            if up and result != up:
                dis.append(("upstream", tid, model, f"{result} vs upstream {up}"))
        decided = {m: v for m, v in res.items() if v in ("allowed", "forbidden") and m not in BASELINES}
        if len(set(decided.values())) > 1:
            detail = ", ".join(f"{m}={v}" for m, v in sorted(decided.items()))
            dis.append(("models", tid, "*", detail))
        if decided and set(decided.values()) == {"forbidden"} and res.get("rvwmo") == "allowed":
            dis.append(("lowering", tid, "rvwmo", "PTX forbids the outcome, the RVWMO lowering allows it"))
    summary = suite.parents[1] / "evidence" / "litmus-h100" / "summary.csv"
    if summary.exists():
        for r in read_csv(summary):
            if int(r["weak"] or 0) == 0:
                continue
            against = sorted(m for m, v in by_test.get(r["test"], {}).items() if v == "forbidden" and m not in BASELINES)
            if against:
                dis.append(("h100", r["test"], r["config"],
                            f"{r['weak']} of {r['instances']} instances, forbidden by {', '.join(against)}"))
    errors += coverage_errors(suite.parents[1])
    errors += kamui_errors(suite, tests, hand, by_test)
    for tid, res in sorted(by_test.items()):
        ptx = {v for m, v in res.items() if v in ("allowed", "forbidden") and m not in BASELINES}
        for m in sorted(KAMUI_MODELS & set(res)):
            if ptx == {"forbidden"} and res[m] == "allowed":
                dis.append(("kamui", tid, m, "PTX forbids the outcome, the Kamui lowering allows it"))
    return errors, dis


def kamui_errors(suite: Path, tests: dict, hand: dict, by_test: dict) -> list[str]:
    root = suite.parents[1]
    errors = []
    kp, pp = root / "models" / "kamui" / "kamui.als", root / "models" / "ptx87" / "ptx87.als"
    if kp.exists() and pp.exists():
        k, p = kp.read_text(), pp.read_text()
        if "\nmodule kamui\n" not in k or k.split("\nmodule kamui\n", 1)[1] != p.split("\nmodule ptx87\n", 1)[1]:
            errors.append("kamui: models/kamui/kamui.als differs from models/ptx87/ptx87.als below the module line")
    for tid in tests:
        for m in sorted(KAMUI_MODELS):
            if to_kamui.kamui_query_for(tid, m) and m not in by_test.get(tid, {}):
                errors.append(f"{tid}: no {m} row in expected.csv")
    for tid, t in hand.items():
        want = t.comments.strip().strip('"').rstrip(".").split(":")[-1].strip()
        if want not in ("allowed", "forbidden"):
            errors.append(f"{tid}: the description must end with ': allowed.' or ': forbidden.'")
        elif by_test.get(tid, {}).get("kamui-alloy") != want:
            errors.append(f"{tid}: kamui-alloy says {by_test.get(tid, {}).get('kamui-alloy')}, the test says {want}")
    return errors


def stronger(suite: Path = SUITE) -> list[tuple[str, str]]:
    """Tests where a Kamui lowering forbids an outcome that the PTX models allow."""
    by_test: dict[str, dict[str, str]] = defaultdict(dict)
    for r in read_csv(suite / "expected.csv"):
        by_test[r["test"]][r["model"]] = r["result"]
    out = []
    for tid, res in sorted(by_test.items()):
        ptx = {v for m, v in res.items() if v in ("allowed", "forbidden") and m not in BASELINES}
        for m in sorted(KAMUI_MODELS & set(res)):
            if ptx == {"allowed"} and res[m] == "forbidden":
                out.append((tid, m))
    return out


MEMORY_SECTIONS = ("5.1.", "9.7.9.", "9.7.13.", "9.7.14.5.15", "9.7.14.5.16", "9.7.15.")
COVERAGE_KINDS = {"modelled", "no-effect", "outside"}


def coverage_errors(root: Path) -> list[str]:
    """Every catalog feature in the memory-related sections has a row in models/ptx87/coverage.yaml."""
    cat_path, cov_path = root / "tests" / "corpus" / "catalog.yaml", root / "models" / "ptx87" / "coverage.yaml"
    if not cat_path.exists() or not cov_path.exists():
        return [f"coverage: {cov_path.relative_to(root)} or {cat_path.relative_to(root)} missing"]
    catalog = yaml.safe_load(cat_path.read_text())
    feats = catalog["features"] if isinstance(catalog, dict) else catalog
    ids = {f["id"]: str(f.get("manual_section", "")).split(" ")[0] + "." for f in feats
           if f.get("status") == "in-scope"}
    wanted = {i for i, sec in ids.items() if sec.startswith(MEMORY_SECTIONS)}
    rows = yaml.safe_load(cov_path.read_text()) or []
    errors, seen = [], set()
    for r in rows:
        fid = r.get("feature")
        if fid not in ids:
            errors.append(f"coverage: unknown feature {fid!r}")
        if r.get("kind") not in COVERAGE_KINDS:
            errors.append(f"coverage: {fid}: kind must be one of {sorted(COVERAGE_KINDS)}")
        if not str(r.get("how", "")).strip():
            errors.append(f"coverage: {fid}: no 'how'")
        if fid in seen:
            errors.append(f"coverage: {fid} listed twice")
        seen.add(fid)
    for fid in sorted(wanted - seen):
        errors.append(f"coverage: catalog feature {fid} (section {ids[fid][:-1]}) has no row in coverage.yaml")
    lowering = yaml.safe_load((root / "models" / "kamui" / "lowering.yaml").read_text())["features"]
    for r in rows:
        if r.get("kind") == "modelled" and r.get("kamui") != lowering.get(r.get("feature")):
            errors.append(f"coverage: {r.get('feature')}: kamui field {r.get('kamui')} is not the lowering of "
                          f"models/kamui/lowering.yaml ({lowering.get(r.get('feature'))})")
    return errors


def load_allowlist(path: Path = ALLOWLIST) -> list[dict]:
    if not path.exists():
        return []
    return yaml.safe_load(path.read_text()) or []


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="print every disagreement")
    ap.add_argument("--stronger", action="store_true", help="list where a Kamui lowering is stronger than PTX")
    a = ap.parse_args()
    if a.stronger:
        for tid, m in stronger():
            print(f"{m:16} {tid}")
        return 0
    errors, dis = findings()
    allow = load_allowlist()
    keys = {(e["kind"], e["test"], e.get("model", "*")): e for e in allow}
    for e in allow:
        if not e.get("reason", "").strip():
            errors.append(f"allowlist: entry {e['kind']} {e['test']} has no reason")
    used = set()
    for kind, tid, model, detail in dis:
        k = (kind, tid, model)
        if k in keys:
            used.add(k)
            if a.list:
                print(f"explained  {kind:9} {tid} [{model}] {detail}")
        else:
            errors.append(f"unexplained {kind} disagreement: {tid} [{model}] {detail}")
    for k in sorted(set(keys) - used):
        errors.append(f"allowlist: stale entry {k}")
    for e in errors:
        print(e)
    n_rows = len(read_csv(EXPECTED))
    print(f"{n_rows} rows, {len(dis)} disagreements ({len(used)} explained), {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

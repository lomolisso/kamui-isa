import csv
import shutil
from pathlib import Path

import check_suite

SUITE = Path(__file__).resolve().parents[3] / "tests" / "litmus"


def make_suite(tmp_path: Path) -> Path:
    s = tmp_path / "litmus"
    (s / "ptx" / "imported" / "dat3m").mkdir(parents=True)
    src = SUITE / "ptx" / "imported" / "dat3m" / "Manual" / "MP-cta-gpu.litmus"
    shutil.copy(src, s / "ptx" / "imported" / "dat3m" / "MP.litmus")
    with open(s / "ptx" / "imported" / "origin.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["test", "upstream_ptx_v7_5", "upstream_ptx_v6_0"])
        w.writeheader()
        w.writerow({"test": "ptx/imported/dat3m/MP", "upstream_ptx_v7_5": "forbidden", "upstream_ptx_v6_0": ""})
    return s


def write_expected(s: Path, rows: list[dict]) -> None:
    with open(s / "expected.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=check_suite.FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in check_suite.FIELDS})


def row(model, result):
    return {"test": "ptx/imported/dat3m/MP", "model": model, "tool": "dartagnan", "result": result}


def test_clean_suite(tmp_path):
    s = make_suite(tmp_path)
    write_expected(s, [row("ptx-v7.5", "forbidden"), row("ptx-v6.0", "forbidden")])
    errors, dis = check_suite.findings(s)
    assert errors == [] and dis == []


def test_upstream_and_model_disagreements(tmp_path):
    s = make_suite(tmp_path)
    write_expected(s, [row("ptx-v7.5", "allowed"), row("ptx-v6.0", "forbidden")])
    errors, dis = check_suite.findings(s)
    assert errors == []
    kinds = sorted(d[0] for d in dis)
    assert kinds == ["models", "upstream"]


def test_missing_v75_row_and_bad_result(tmp_path):
    s = make_suite(tmp_path)
    write_expected(s, [row("ptx-v6.0", "maybe")])
    errors, _ = check_suite.findings(s)
    assert any("no ptx-v7.5 row" in e for e in errors)
    assert any("bad result" in e for e in errors)


def test_committed_suite_is_consistent():
    errors, dis = check_suite.findings()
    assert errors == []
    allow = {(e["kind"], e["test"], e.get("model", "*")) for e in check_suite.load_allowlist()}
    assert {(k, t, m) for k, t, m, _ in dis} == allow

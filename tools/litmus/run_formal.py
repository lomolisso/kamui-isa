#!/usr/bin/env python3
"""Run the litmus tests through the formal memory-model tools and write tests/litmus/expected.csv.

    python tools/litmus/run_formal.py                 # every test, every model that applies
    python tools/litmus/run_formal.py --tests 'ptx/imported/dat3m/Manual/*' --models ptx-v7.5
    python tools/litmus/run_formal.py --check         # re-run everything; fail if expected.csv would change

Runs in the dev container (needs Java and Dartagnan). Every test's condition is an `exists` condition, so the
answer is one word: `allowed` (some execution the model accepts satisfies the condition), `forbidden` (none
does), `unknown` (the tool could not decide, for example a loop it could not unroll completely) or `error`.

Models (column `model`):
- `ptx-v7.5`: Dartagnan with `cat/ptx-v7.5.cat`, the mixed-proxy PTX model (PTX ISA 7.5). Every test without
  `.cluster`.
- `ptx-v6.0`: Dartagnan with `cat/ptx-v6.0.cat`, the PTX ISA 6.0 model (no proxies). Tests without `.cluster`
  and without proxy features.
- `manual-reasoning`: a verdict argued by hand from the PTX ISA 8.7 manual, for tests no tool can decide. The
  argument is in tests/litmus/manual-reasoning.yaml; these rows are copied, not computed.
Dartagnan runs as in Dat3M's own unit tests: `--method=eager` (the lazy method gives wrong answers for some
v7.5 tests, Dat3M issue #1039), loop bound 1, the Z3 solver. A test can ask for other flags in
tests/litmus/formal-flags.yaml.

Partial runs (`--tests`, `--models`) replace only the rows they produce. `--check` compares every column except
`runtime_s`.
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import hashlib
import io
import os
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import litmus  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "tests" / "litmus"
EXPECTED = SUITE / "expected.csv"
FLAGS_FILE = SUITE / "formal-flags.yaml"
FIELDS = ["test", "source", "condition", "model", "model_version", "tool", "tool_version", "flags", "result",
          "runtime_s"]
DAT3M = Path(os.environ.get("DAT3M_HOME", "/opt/dat3m"))
DARTAGNAN_FLAGS = "--target=ptx --method=eager --bound=1 --solver=z3 --property=program_spec"


def all_tests() -> list[Path]:
    return sorted((SUITE / "ptx").rglob("*.litmus"))


def test_id(path: Path) -> str:
    return path.relative_to(SUITE).with_suffix("").as_posix()


def source_of(tid: str) -> str:
    parts = tid.split("/")
    return parts[2] if parts[1] == "imported" else parts[1]


def file_sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:12]


class Dartagnan:
    tool = "dartagnan"

    def __init__(self, model: str, cat: str):
        self.model, self.cat = model, DAT3M / "cat" / cat
        self._version = None

    def applies(self, t: litmus.Litmus) -> bool:
        if t.uses_cluster:
            return False
        return not (self.model == "ptx-v6.0" and t.uses_proxy)

    @property
    def model_version(self) -> str:
        return f"{self.cat.name} sha256:{file_sha(self.cat)}"

    @property
    def tool_version(self) -> str:
        if self._version is None:
            out = subprocess.run(["dartagnan", "--version"], capture_output=True, text=True).stdout.strip()
            self._version = out.splitlines()[-1] if out else "?"
        return self._version

    def run(self, path: Path, extra: str) -> tuple[str, float, str]:
        flags = f"{DARTAGNAN_FLAGS} {extra}".strip()
        with tempfile.TemporaryDirectory(dir=_outdir()) as out:
            env = dict(os.environ, DAT3M_OUTPUT=out)
            t0 = time.monotonic()
            p = subprocess.run(["dartagnan", str(self.cat), *flags.split(), str(path)], capture_output=True,
                               text=True, env=env, timeout=600)
            dt = time.monotonic() - t0
        m = re.search(r"^Result:\s*(\w+)", p.stdout, re.M)
        word = m.group(1) if m else "ERROR"
        result = {"PASS": "allowed", "FAIL": "forbidden", "UNKNOWN": "unknown"}.get(word, "error")
        if result == "error":
            sys.stderr.write(f"{test_id(path)} ({self.model}): {p.stdout[-400:]}{p.stderr[-400:]}\n")
        return result, dt, flags


def _outdir() -> str:
    d = ROOT / "build" / "litmus" / "dat3m-output"
    d.mkdir(parents=True, exist_ok=True)
    return str(d)


class Manual:
    """Verdicts argued by hand (tests/litmus/manual-reasoning.yaml): `test`, `result`, `argument`."""

    tool, model, model_version, tool_version = "manual", "manual-reasoning", "PTX ISA 8.7", ""
    path = SUITE / "manual-reasoning.yaml"

    def entries(self) -> dict:
        if not self.path.exists():
            return {}
        return {e["test"]: e for e in (yaml.safe_load(self.path.read_text()) or [])}

    def applies(self, t: litmus.Litmus) -> bool:
        return False  # handled in run_jobs from the YAML file, not per test

    def run(self, path: Path, extra: str):
        e = self.entries()[test_id(path)]
        return e["result"], None, ""


MODELS = {
    "ptx-v7.5": Dartagnan("ptx-v7.5", "ptx-v7.5.cat"),
    "ptx-v6.0": Dartagnan("ptx-v6.0", "ptx-v6.0.cat"),
    "manual-reasoning": Manual(),
}
TOOLS = {m.tool for m in MODELS.values()}


def read_rows(path: Path = EXPECTED) -> list[dict]:
    if not path.exists():
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def format_rows(rows: list[dict]) -> str:
    rows = sorted(rows, key=lambda r: (r["test"], r["model"], r["tool"]))
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=FIELDS, lineterminator="\n")
    w.writeheader()
    for r in rows:
        w.writerow({k: r.get(k, "") for k in FIELDS})
    return buf.getvalue()


def load_flags() -> dict:
    if not FLAGS_FILE.exists():
        return {}
    return {e["test"]: e for e in (yaml.safe_load(FLAGS_FILE.read_text()) or [])}


def plan(tests: list[Path], models: list[str]) -> list[tuple[Path, litmus.Litmus, str]]:
    manual = MODELS["manual-reasoning"].entries() if "manual-reasoning" in models else {}
    jobs = []
    for p in tests:
        t = litmus.load(p)
        for m in models:
            if MODELS[m].applies(t) or (m == "manual-reasoning" and test_id(p) in manual):
                jobs.append((p, t, m))
    return jobs


def run_jobs(jobs, nproc: int) -> list[dict]:
    flags = load_flags()

    def one(job):
        p, t, m = job
        tid = test_id(p)
        res, dt, fl = MODELS[m].run(p, flags.get(tid, {}).get("flags", {}).get(m, ""))
        return {"test": tid, "source": source_of(tid), "condition": t.cond_text, "model": m,
                "model_version": MODELS[m].model_version, "tool": MODELS[m].tool,
                "tool_version": MODELS[m].tool_version, "flags": fl, "result": res,
                "runtime_s": "" if dt is None else f"{dt:.1f}"}

    for m in {j[2] for j in jobs}:
        _ = MODELS[m].tool_version, MODELS[m].model_version
    with ThreadPoolExecutor(nproc) as ex:
        rows = []
        for k, r in enumerate(ex.map(one, jobs), 1):
            rows.append(r)
            if k % 50 == 0:
                print(f"  {k}/{len(jobs)}", file=sys.stderr)
    return rows


def merge(old: list[dict], new: list[dict], models: list[str], tests: set[str]) -> list[dict]:
    """Drop the old rows this run is responsible for, then add the new ones."""
    owned = {(r["test"], r["model"]) for r in new}
    keep = [r for r in old
            if (r["test"], r["model"]) not in owned and not (r["model"] in models and r["test"] in tests)]
    return keep + new


def strip_runtime(text: str) -> list[tuple]:
    rows = list(csv.DictReader(io.StringIO(text)))
    return sorted(tuple(r.get(k, "") for k in FIELDS if k != "runtime_s") for r in rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tests", default="*", help="glob over test ids, e.g. 'ptx/imported/dat3m/Manual/*'")
    ap.add_argument("--models", default=",".join(MODELS), help="comma-separated models")
    ap.add_argument("--jobs", type=int, default=min(32, os.cpu_count() or 4))
    ap.add_argument("--check", action="store_true", help="re-run and compare with expected.csv (ignores runtime_s)")
    a = ap.parse_args()
    models = [m for m in a.models.split(",") if m]
    for m in models:
        if m not in MODELS:
            ap.error(f"unknown model {m}; known: {', '.join(MODELS)}")
    tests = [p for p in all_tests() if fnmatch.fnmatch(test_id(p), a.tests)]
    jobs = plan(tests, models)
    print(f"{len(tests)} tests, {len(jobs)} runs", file=sys.stderr)
    t0 = time.monotonic()
    new = run_jobs(jobs, a.jobs)
    print(f"done in {time.monotonic() - t0:.0f} s", file=sys.stderr)
    old = read_rows()
    merged = format_rows(merge(old, new, models, {test_id(p) for p in tests}))
    if a.check:
        cur = EXPECTED.read_text(encoding="utf-8") if EXPECTED.exists() else ""
        a_rows, b_rows = set(strip_runtime(cur)), set(strip_runtime(merged))
        for r in sorted(a_rows - b_rows):
            print(f"- {','.join(r)}")
        for r in sorted(b_rows - a_rows):
            print(f"+ {','.join(r)}")
        print(f"expected.csv {'is current' if a_rows == b_rows else 'would change'}")
        return 0 if a_rows == b_rows else 1
    EXPECTED.write_text(merged, encoding="utf-8")
    counts = {}
    for r in new:
        counts[(r["model"], r["result"])] = counts.get((r["model"], r["result"]), 0) + 1
    for (m, res), n in sorted(counts.items()):
        print(f"{m:10} {res:10} {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Check the committed golden outputs in tests/goldens/ against the corpus, without a GPU.

    python tools/evidence/check_goldens.py

For every corpus entry that runs (not `run: false`) it checks that:
- tests/goldens/<id>/golden.yaml exists and was made from the current kernel.ptx and inputs.bin (sha256), so a
  changed kernel or generator makes its golden stale;
- the run succeeded, unless the entry's tolerance is `property:launch_fails`;
- outputs.bin has the size of the entry's output and inout buffers, and its sha256 and each buffer's sha256 match
  golden.yaml; the tolerance in golden.yaml is the entry's;
- a deterministic entry gave identical outputs in every run;
- tests/goldens/manifest.yaml lists every golden with the same sha256 values.
It also reports golden folders that no entry owns.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "corpus"))
sys.path.insert(0, str(ROOT / "tools" / "runner"))
import gen_inputs  # noqa: E402
import run_all  # noqa: E402

CORPUS = ROOT / "tests" / "corpus"
GOLDENS = ROOT / "tests" / "goldens"


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def check_entry(d: Path, manifest: dict) -> list[str]:
    e = yaml.safe_load((d / "entry.yaml").read_text())
    eid = d.name
    g = GOLDENS / eid
    errs = []
    if not (g / "golden.yaml").exists():
        return [f"{eid}: no golden"]
    gy = yaml.safe_load((g / "golden.yaml").read_text())
    if gy.get("ptx_sha256") != sha((d / "kernel.ptx").read_bytes()):
        errs.append(f"{eid}: stale golden, kernel.ptx changed since the run")
    if gy.get("inputs_sha256") != sha(gen_inputs.inputs_bin(d)):
        errs.append(f"{eid}: stale golden, inputs.bin changed since the run")
    if gy.get("tolerance") != e["tolerance_class"]:
        errs.append(f"{eid}: golden tolerance {gy.get('tolerance')} is not the entry's {e['tolerance_class']}")
    result = str(gy.get("result", ""))
    m = manifest.get(eid)
    if m is None:
        errs.append(f"{eid}: not in manifest.yaml")
    elif m.get("golden_yaml_sha256") != sha((g / "golden.yaml").read_bytes()):
        errs.append(f"{eid}: golden.yaml sha256 differs from manifest.yaml")
    if e["tolerance_class"] == "property:launch_fails":
        if not result.startswith("launch-error"):
            errs.append(f"{eid}: expected the launch to fail, got {result!r}")
        return errs
    if result != "ok":
        return errs + [f"{eid}: run did not succeed: {result}"]
    data = (g / "outputs.bin").read_bytes() if (g / "outputs.bin").exists() else None
    if data is None:
        return errs + [f"{eid}: no outputs.bin"]
    want = sum(b["bytes"] for b in run_all.buffers(e) if b["out"] >= 0)
    if len(data) != want:
        errs.append(f"{eid}: outputs.bin has {len(data)} bytes, the entry's outputs need {want}")
    if gy.get("outputs_sha256") != sha(data):
        errs.append(f"{eid}: outputs.bin sha256 differs from golden.yaml")
    if m is not None and m.get("outputs_bin_sha256") != sha(data):
        errs.append(f"{eid}: outputs.bin sha256 differs from manifest.yaml")
    for o in gy.get("outputs", []):
        if sha(data[o["offset"]: o["offset"] + o["bytes"]]) != o["sha256"]:
            errs.append(f"{eid}: buffer {o['name']} sha256 differs from golden.yaml")
    if e.get("deterministic", True) and not gy.get("runs_identical"):
        errs.append(f"{eid}: deterministic entry, but its runs gave different outputs")
    return errs


def main() -> int:
    mpath = GOLDENS / "manifest.yaml"
    if not mpath.exists():
        print("missing tests/goldens/manifest.yaml")
        return 1
    manifest = {m["id"]: m for m in (yaml.safe_load(mpath.read_text()) or {}).get("entries", [])}
    dirs = sorted(p.parent for p in CORPUS.glob("*/*/entry.yaml"))
    runnable = [d for d in dirs if yaml.safe_load((d / "entry.yaml").read_text()).get("run") is not False]
    errs = []
    for d in runnable:
        errs += check_entry(d, manifest)
    owned = {d.name for d in runnable}
    errs += [f"{p.name}: golden folder without a runnable entry" for p in sorted(GOLDENS.iterdir())
             if p.is_dir() and p.name not in owned]
    for e in errs:
        print(e)
    print(f"goldens: {len(runnable)} runnable entries, {len(errs)} problems")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())

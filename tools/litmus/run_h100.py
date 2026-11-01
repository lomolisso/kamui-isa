#!/usr/bin/env python3
"""Run the litmus kernels on the GPU (used by jobs/litmus-h100.sh on the H100 server).

    python tools/litmus/run_h100.py --runner build/litmus_runner --out OUT [--tests GLOB] [--configs plain,stress]
                                    [--instances N] [--shard K/N] [--timeout S] [--dry-run]

For each test with a kernel in tests/litmus/h100/ (matching --tests, a glob over test ids such as
'ptx/kamui/families/MP/*') and each configuration, it runs tools/litmus/runner/litmus_runner and keeps its JSON
as OUT/results/<test path>/<config>.json. The seed is derived from the test id and the configuration, so a run
can be repeated. --shard K/N runs every N-th test starting at K (0-based), to split the work into several jobs.
--dry-run prints the commands without running them (no GPU needed).

OUT/run.yaml records, for every run: the test, the configuration, the exit status and the time. Turning the
results into evidence/litmus-h100/observed.csv is tools/litmus/observed.py's job.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import os
import subprocess
import sys
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "tests" / "litmus"
H100 = SUITE / "h100"
sys.path.insert(0, str(ROOT / "tools" / "runner"))
from run_all import gpu_info  # noqa: E402


def kernels() -> list[tuple[str, Path]]:
    """(test id, kernel directory) for every generated kernel."""
    out = []
    for spec in sorted(H100.rglob("spec.txt")):
        d = spec.parent
        out.append(("ptx/" + d.relative_to(H100).as_posix(), d))
    return out


def seed_of(tid: str, config: str) -> int:
    return int.from_bytes(hashlib.sha256(f"{tid}|{config}".encode()).digest()[:4], "little") or 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runner", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--tests", default="*")
    ap.add_argument("--configs", default="plain,stress,shuffle")
    ap.add_argument("--instances", type=int, default=1000000)
    ap.add_argument("--shard", default="0/1")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    k, n = (int(x) for x in a.shard.split("/"))
    todo = [(tid, d) for tid, d in kernels() if fnmatch.fnmatch(tid, a.tests)][k::n]
    configs = [c for c in a.configs.split(",") if c]
    env = dict(os.environ, CUDA_CACHE_DISABLE="1")
    runs, failed = [], 0
    t_start = time.monotonic()
    for i, (tid, d) in enumerate(todo, 1):
        for c in configs:
            dest = a.out / "results" / tid.removeprefix("ptx/") / f"{c}.json"
            cmd = [str(a.runner), str(d / "spec.txt"), str(d / "kernel.ptx"), str(dest),
                   "--instances", str(a.instances), "--config", c, "--seed", str(seed_of(tid, c))]
            if a.dry_run:
                print(" ".join(cmd))
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            t0 = time.monotonic()
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=a.timeout, env=env)
                rc, msg = p.returncode, (p.stdout + p.stderr).strip().splitlines()[-1:] or [""]
            except subprocess.TimeoutExpired:
                rc, msg = -1, ["timeout"]
            dt = time.monotonic() - t0
            failed += rc != 0
            runs.append({"test": tid, "config": c, "exit": rc, "seconds": round(dt, 2), "message": msg[0][:300]})
            print(f"[{i}/{len(todo)}] {tid} {c}: {'ok' if rc == 0 else f'FAILED ({rc}) ' + msg[0]} {dt:.1f} s",
                  flush=True)
    if a.dry_run:
        return 0
    a.out.mkdir(parents=True, exist_ok=True)
    meta = {"gpu": gpu_info(), "instances": a.instances, "configs": configs, "tests": a.tests, "shard": a.shard,
            "seconds": round(time.monotonic() - t_start, 1), "failed": failed, "runs": runs}
    (a.out / "run.yaml").write_text(yaml.safe_dump(meta, sort_keys=False, width=120))
    print(f"summary: {len(runs)} runs, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

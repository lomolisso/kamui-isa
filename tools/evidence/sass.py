#!/usr/bin/env python3
"""ptxas and SASS evidence for every corpus entry, and the per-feature SASS observations.

    python tools/evidence/sass.py                # extract (needs ptxas, cuobjdump, nvdisasm) and annotate
    python tools/evidence/sass.py --extract      # only write evidence/ptxas/ and evidence/sass/ (+ build/evidence/)
    python tools/evidence/sass.py --annotate     # only rewrite evidence/sass-observations.csv from build/evidence/
    python tools/evidence/sass.py --verify       # extract again into build/, compare with the committed files
    python tools/evidence/sass.py --check        # no tools: every in-scope row has ptxas, SASS and a CSV row

For each entry directory under tests/corpus/ it runs, inside the dev container (CUDA 12.8):

    ptxas -arch=sm_90a -v <compile.ptxas_flags> -o build/evidence/cubin/<id>.cubin kernel.ptx
    cuobjdump -sass -res-usage <cubin>     -> evidence/sass/<id>.sass
    nvdisasm -json <cubin>                 -> build/evidence/json/<id>.json (parsed, not committed)

and writes the ptxas output (without the compile time, which changes from run to run) to
evidence/ptxas/<id>.txt. <id> is the entry directory name: the feature id with `::` written as `.`.

The annotation step reads the SASS of each entry and, for every in-scope catalog row, finds the SASS
instructions that implement the row's PTX (see sass_classes.yaml and annotate.py), and writes one CSV row per
catalog row. Rows that need a human look are listed in build/evidence/review.tsv; the decisions of that review
live in sass-review.yaml next to this script and are applied on every run.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "catalog"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

CORPUS = ROOT / "tests" / "corpus"
EVIDENCE = ROOT / "evidence"
PTXAS_DIR, SASS_DIR = EVIDENCE / "ptxas", EVIDENCE / "sass"
CSV = EVIDENCE / "sass-observations.csv"
BUILD = ROOT / "build" / "evidence"
PTXAS = os.environ.get("KAMUI_PTXAS", "ptxas")
CUOBJDUMP = os.environ.get("KAMUI_CUOBJDUMP", "cuobjdump")
NVDISASM = os.environ.get("KAMUI_NVDISASM", "nvdisasm")
COMPILE_TIME_RE = re.compile(r"^ptxas info\s*: Compile time = .*\n?", re.M)


def entry_dirs() -> list[Path]:
    return sorted(p.parent for p in CORPUS.glob("*/*/entry.yaml"))


def entry_id(d: Path) -> str:
    return d.name


def ptxas_flags(d: Path) -> list[str]:
    e = yaml.safe_load((d / "entry.yaml").read_text())
    return list((e.get("compile") or {}).get("ptxas_flags") or [])


def run(cmd: list[str]) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout + r.stderr


def extract_one(d: Path, ptxas_dir: Path, sass_dir: Path, build: Path) -> tuple[str, str | None]:
    """Write <id>.txt (ptxas -v), <id>.sass (cuobjdump) and the nvdisasm JSON for one entry."""
    eid = entry_id(d)
    rel = d.relative_to(ROOT)
    cubin = build / "cubin" / f"{eid}.cubin"
    try:
        flags = ptxas_flags(d)
        out = run([PTXAS, "-arch=sm_90a", "-v", *flags, "-o", str(cubin), str(rel / "kernel.ptx")])
        head = f"# {' '.join(['ptxas', '-arch=sm_90a', '-v', *flags, '-o', eid + '.cubin', str(rel / 'kernel.ptx')])}\n"
        (ptxas_dir / f"{eid}.txt").write_text(head + COMPILE_TIME_RE.sub("", out))
        sass = run([CUOBJDUMP, "-sass", "-res-usage", str(cubin)])
        sass = sass.replace(str(cubin), f"{eid}.cubin")
        (sass_dir / f"{eid}.sass").write_text(f"# cuobjdump -sass -res-usage {eid}.cubin\n" + sass)
        (build / "json" / f"{eid}.json").write_text(run([NVDISASM, "-json", str(cubin)]))
    except (RuntimeError, OSError) as e:
        return eid, str(e)
    return eid, None


def extract(dirs: list[Path], ptxas_dir: Path, sass_dir: Path, build: Path, jobs: int) -> int:
    for p in (ptxas_dir, sass_dir, build / "cubin", build / "json"):
        p.mkdir(parents=True, exist_ok=True)
    with ProcessPoolExecutor(max_workers=jobs) as ex:
        res = list(ex.map(extract_one, dirs, [ptxas_dir] * len(dirs), [sass_dir] * len(dirs),
                          [build] * len(dirs)))
    bad = [(e, m) for e, m in res if m]
    for e, m in bad:
        print(f"FAIL {e}: {m}")
    print(f"extracted {len(dirs) - len(bad)} of {len(dirs)} entries")
    return 1 if bad else 0


def verify(dirs: list[Path], jobs: int) -> int:
    """Extract again into build/evidence/verify/ and compare with the committed files."""
    v = BUILD / "verify"
    rc = extract(dirs, v / "ptxas", v / "sass", v, jobs)
    diff = []
    for d in dirs:
        eid = entry_id(d)
        for new, old in ((v / "ptxas" / f"{eid}.txt", PTXAS_DIR / f"{eid}.txt"),
                         (v / "sass" / f"{eid}.sass", SASS_DIR / f"{eid}.sass")):
            if not old.exists() or new.read_text() != old.read_text():
                diff.append(str(old.relative_to(ROOT)))
    for p in diff:
        print(f"DIFFERS {p}")
    print(f"verify: {len(dirs) * 2 - len(diff)} of {len(dirs) * 2} files identical")
    return 1 if (rc or diff) else 0


def load_json(eid: str, build: Path = BUILD) -> list[dict]:
    """The functions of one entry's cubin as nvdisasm -json reports them."""
    data = json.loads((build / "json" / f"{eid}.json").read_text())
    return data[1]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--extract", action="store_true")
    g.add_argument("--annotate", action="store_true")
    g.add_argument("--verify", action="store_true")
    g.add_argument("--check", action="store_true")
    ap.add_argument("-j", "--jobs", type=int, default=min(32, os.cpu_count() or 1))
    args = ap.parse_args(argv)
    import annotate  # noqa: PLC0415  (kept separate so --check needs no tools)
    if args.check:
        return annotate.check(common.load_catalog())
    if args.verify:
        return verify(entry_dirs(), args.jobs)
    rc = 0
    if not args.annotate:
        rc = extract(entry_dirs(), PTXAS_DIR, SASS_DIR, BUILD, args.jobs)
    if not args.extract and rc == 0:
        rc = annotate.write_csv(common.load_catalog())
    return rc


if __name__ == "__main__":
    sys.exit(main())

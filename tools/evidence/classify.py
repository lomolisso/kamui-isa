#!/usr/bin/env python3
"""Classify the raw NVBit histograms and write evidence/histograms/.

    python tools/evidence/classify.py RAW_DIR VERSIONS_YAML [--job-id ID] [--ncu NCU_CSV WORKLOAD]

RAW_DIR holds one CSV per workload from kamui_sass_hist (jobs/nvbit-hist.sh, raw/<workload>.csv). For each it
writes evidence/histograms/<workload>.csv with the columns

    workload, kernel, sass_opcode, opcode_class, static_count, warp_inst_executed, thread_inst_executed,
    thread_inst_executed_pred_true

sorted by kernel and by warp_inst_executed (largest first), after a few `#` comment lines that record the job,
the GPU and the tool and library versions. opcode_class comes from opcode_classes.yaml; the classes are applied
here and not in the NVBit tool, so the class map can change without another GPU run.

With --ncu it also writes evidence/histograms/ncu-crosscheck.csv: for the first kernel in the Nsight Compute CSV
(`--page raw`, jobs/nvbit-hist.sh MODE=ncu), the warp, thread and predicate-on instruction totals that ncu
measured next to the totals of the same workload's NVBit histogram, and the difference in percent.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "evidence" / "histograms"
COLUMNS = ["workload", "kernel", "sass_opcode", "opcode_class", "static_count", "warp_inst_executed",
           "thread_inst_executed", "thread_inst_executed_pred_true"]


def load_classes(path: Path = HERE / "opcode_classes.yaml") -> list[dict]:
    return yaml.safe_load(path.read_text())["classes"]


def classify(opcode: str, classes: list[dict]) -> str:
    for c in classes:
        if any(re.match(rf"(?:{p})(\.|$)", opcode) for p in c["patterns"]):
            return c["name"]
    return "other"


def read_csv(path: Path) -> list[dict]:
    return list(csv.DictReader(line for line in path.open() if not line.startswith("#")))


def write(raw: Path, header: list[str], classes: list[dict], out_dir: Path = OUT) -> Path:
    rows = read_csv(raw)
    for r in rows:
        r["opcode_class"] = classify(r["sass_opcode"], classes)
    rows.sort(key=lambda r: (r["kernel"], -int(r["warp_inst_executed"]), r["sass_opcode"]))
    out = out_dir / raw.name
    with out.open("w", newline="") as f:
        f.write("".join(f"# {h}\n" for h in header))
        w = csv.DictWriter(f, fieldnames=COLUMNS, lineterminator="\n", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    return out


NCU_METRICS = {"warp_inst_executed": "smsp__inst_executed.sum", "thread_inst_executed": "smsp__thread_inst_executed.sum",
               "thread_inst_executed_pred_true": "smsp__thread_inst_executed_pred_on.sum"}


def ncu_crosscheck(ncu_csv: Path, workload: str, job_ids: str, out_dir: Path = OUT) -> Path:
    rows = list(csv.reader(line for line in ncu_csv.open() if line.startswith('"')))
    head, first = rows[0], rows[2]
    nv = read_csv(out_dir / f"{workload}.csv")
    out = out_dir / "ncu-crosscheck.csv"
    with out.open("w", newline="") as f:
        f.write(f"# {job_ids}\n# kernel: {first[head.index('Kernel Name')].split('<')[0]} of {workload}\n")
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["count", "ncu_metric", "ncu", "nvbit", "difference_percent"])
        for col, metric in NCU_METRICS.items():
            a = int(first[head.index(metric)].replace(",", ""))
            b = sum(int(r[col]) for r in nv)
            w.writerow([col, metric, a, b, f"{100 * (b - a) / a:+.2f}"])
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raw_dir", type=Path)
    ap.add_argument("versions", type=Path)
    ap.add_argument("--job-id", default="")
    ap.add_argument("--ncu", nargs=2, metavar=("NCU_CSV", "WORKLOAD"))
    ap.add_argument("--ncu-job-id", default="")
    args = ap.parse_args(argv)
    v = yaml.safe_load(args.versions.read_text())
    header = [f"job {args.job_id}", f"gpu {v.get('gpu')}, driver {v.get('driver')}",
              "tool kamui_sass_hist (tools/evidence/nvbit), NVBit " + str(v.get("nvbit")),
              ", ".join(f"{k} {v[k]}" for k in ("cuda_toolkit", "cutlass", "torch", "triton", "flash_attn", "flashinfer")
                        if k in v)]
    OUT.mkdir(parents=True, exist_ok=True)
    classes = load_classes()
    for raw in sorted(args.raw_dir.glob("*.csv")):
        out = write(raw, header, classes)
        rows = read_csv(out)
        other = sorted({r["sass_opcode"] for r in rows if r["opcode_class"] == "other"})
        print(f"{out.relative_to(ROOT)}: {len(rows)} rows, {len({r['kernel'] for r in rows})} kernels"
              + (f"; unclassified: {', '.join(other)}" if other else ""))
    if args.ncu:
        out = ncu_crosscheck(Path(args.ncu[0]), args.ncu[1], f"nvbit job {args.job_id}, ncu job {args.ncu_job_id}")
        print(out.read_text())
    return 0


if __name__ == "__main__":
    sys.exit(main())

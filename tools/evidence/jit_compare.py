#!/usr/bin/env python3
"""Compare the SASS the H100 driver JIT produced with the SASS of the offline ptxas in evidence/sass/.

    python tools/evidence/jit_compare.py JIT_SASS_DIR      # writes evidence/jit-comparison.tsv

JIT_SASS_DIR holds `nvdisasm -json` of the cubins dumped on the H100 (jobs/goldens.sh, jit-sass/<id>.json). The
offline side is build/evidence/json/<id>.json from `tools/evidence/sass.py --extract` (ptxas 12.8 in the dev
container). Two kernels match when they have the same functions with the same instruction sequence (predicate,
opcode and modifiers, NOPs dropped); register numbers and immediates are not compared, so a different register
allocation still counts as a match of the instruction selection, and is reported separately.

evidence/jit-comparison.tsv columns: id; match (`yes` same opcodes and operands, `opcodes` same opcodes but
other operands, `no`); offline_insns and jit_insns (instruction counts without NOPs); first_difference (the
first differing instruction, offline then JIT). sass.py --annotate copies `match` into the
`jit_matches_offline` column of sass-observations.csv.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sass as S  # noqa: E402

OUT = S.EVIDENCE / "jit-comparison.tsv"
COLUMNS = ["id", "match", "offline_insns", "jit_insns", "first_difference"]


def insns(path: Path) -> list[tuple[str, str, str]]:
    """(predicate, opcode, operands) of every instruction of every function, NOPs dropped, functions by name."""
    data = json.loads(path.read_text())
    out = []
    for f in sorted(data[1], key=lambda f: f["function-name"]):
        for i in f["sass-instructions"]:
            if i["opcode"] != "NOP":
                out.append((i.get("predicate", ""), i["opcode"], i.get("operands", "")))
    return out


def compare(offline: list[tuple], jit: list[tuple]) -> tuple[str, str]:
    if offline == jit:
        return "yes", ""
    a = [(p, o) for p, o, _ in offline]
    b = [(p, o) for p, o, _ in jit]
    if a == b:
        k = next(k for k, (x, y) in enumerate(zip(offline, jit)) if x != y)
        return "opcodes", f"{' '.join(offline[k]).strip()} | {' '.join(jit[k]).strip()}"
    k = next((k for k, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    left = " ".join(a[k]).strip() if k < len(a) else "(end)"
    right = " ".join(b[k]).strip() if k < len(b) else "(end)"
    return "no", f"at {k}: {left} | {right}"


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 1
    jit_dir = Path(argv[0])
    rows = []
    for p in sorted(jit_dir.glob("*.json")):
        off = S.BUILD / "json" / p.name
        if not off.exists():
            print(f"{p.stem}: no offline SASS (run sass.py --extract first)")
            return 1
        a, b = insns(off), insns(p)
        match, diff = compare(a, b)
        rows.append([p.stem, match, str(len(a)), str(len(b)), diff.replace("\t", " ")])
    OUT.write_text("\t".join(COLUMNS) + "\n" + "".join("\t".join(r) + "\n" for r in rows))
    counts = {m: sum(1 for r in rows if r[1] == m) for m in ("yes", "opcodes", "no")}
    print(f"{OUT.relative_to(ROOT)}: {len(rows)} kernels; " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

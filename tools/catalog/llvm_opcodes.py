#!/usr/bin/env python3
"""List every PTX opcode that clang 20 can print: the input of coverage check B.

Two sources:

1. The NVPTX back end of LLVM 20.1.8. `llvm-tblgen -print-records` expands its TableGen files into plain
   records; every record that derives from `Instruction` has an `AsmString`, the text the back end prints.
2. The `asm(...)` strings of clang's CUDA wrapper headers (`__clang_cuda_*.h`), which clang inserts into
   ordinary CUDA code.

From each string the script deletes operand modifiers (`${mode:base}`), splits it into statements at `;`, `{`
and `}`, drops predicate guards (`@%p`) and declarations (`.reg ...`), and keeps the first word of each
statement up to the first `$`, for example `shfl.sync.bfly.b32`.

    python tools/catalog/llvm_opcodes.py --records build/catalog/nvptx-records.txt --headers <dir>
    python tools/catalog/llvm_opcodes.py --refresh     # make the records with llvm-tblgen, rewrite the snapshot

Output columns: opcode, records (how many records print it), example (one record or header name), source
(`tblgen` or `header`).
"""

from __future__ import annotations

import argparse
import collections
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

FIELDS = ["opcode", "records", "example", "source"]
HEADERS = Path("/usr/lib/llvm-20/lib/clang/20/include")


def statements(asm: str) -> list[str]:
    """Opcodes printed by one assembly string."""
    s = asm.replace("\\t", " ").replace("\\n", " ").replace("\t", " ").replace("\n", " ")
    s = re.sub(r"\$\{[^}]*\}", "", s)
    out = []
    for stmt in re.split(r"[;{}]", s):
        stmt = stmt.strip()
        stmt = re.sub(r"^@!?%?\S+\s+", "", stmt).strip()
        if not stmt or stmt.startswith((".", "//", "$", "#", "%")):
            continue
        word = re.sub(r"\.{2,}", ".", stmt.split()[0].split("$")[0]).rstrip(".")
        if not re.match(r"^[a-z][a-z0-9_]*(\.[A-Za-z0-9_:]+)*$", word):
            continue
        out.append(word)
    return out


def from_records(text: str) -> dict[str, list[str]]:
    """opcode -> record names, from `llvm-tblgen -print-records` output."""
    defs_part = text.split("------------- Defs -----------------", 1)[-1]
    found: dict[str, list[str]] = collections.defaultdict(list)
    for d in re.split(r"\n(?=def )", defs_part):
        head = d.split("\n", 1)[0]
        m = re.match(r"def (\S+)\s*\{\s*//(.*)", head)
        if not m or " Instruction" not in " " + m.group(2) + " ":
            continue
        a = re.search(r'string AsmString = "(.*)";', d)
        if not a or not a.group(1).strip():
            continue
        for op in statements(a.group(1)):
            found[op].append(m.group(1))
    return found


def from_headers(paths: list[Path]) -> dict[str, list[str]]:
    """opcode -> header names, from the asm(...) strings of the CUDA wrapper headers."""
    found: dict[str, list[str]] = collections.defaultdict(list)
    for p in paths:
        text = p.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r"\b(?:__)?asm(?:__)?\s*(?:(?:__)?volatile(?:__)?\s*)?\(((?:\s*\"(?:[^\"\\]|\\.)*\")+)", text):
            strings = re.findall(r"\"((?:[^\"\\]|\\.)*)\"", m.group(1))
            asm = "".join(strings)
            asm = re.sub(r"%\d+|%[a-z]\d*", "R", asm)  # operand placeholders
            for op in statements(asm):
                found[op].append(p.name)
    return found


def collect(records_text: str, header_paths: list[Path]) -> list[dict]:
    rows = []
    for source, found in (("tblgen", from_records(records_text)), ("header", from_headers(header_paths))):
        for op in sorted(found):
            rows.append({"opcode": op, "records": len(found[op]), "example": sorted(found[op])[0],
                         "source": source})
    return rows


def make_records(out: Path) -> Path:
    llvm = common.llvm_dir()
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["llvm-tblgen-20" if _has("llvm-tblgen-20") else "llvm-tblgen", "-print-records",
         "-I", str(llvm / "include"), "-I", str(llvm / "lib/Target/NVPTX"),
         str(llvm / "lib/Target/NVPTX/NVPTX.td"), "-o", str(out)],
        check=True,
    )
    return out


def _has(cmd: str) -> bool:
    from shutil import which
    return which(cmd) is not None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--records", type=Path, help="llvm-tblgen -print-records output (made if absent)")
    ap.add_argument("--headers", type=Path, default=HEADERS, help="directory of __clang_cuda_*.h")
    ap.add_argument("--refresh", action="store_true", help="rewrite the committed snapshot")
    ap.add_argument("-o", "--output", type=Path)
    args = ap.parse_args(argv)
    records = args.records or common.ROOT / "build" / "catalog" / "nvptx-records.txt"
    if not records.exists():
        make_records(records)
    headers = sorted(args.headers.glob("__clang_cuda_*.h"))
    rows = collect(records.read_text(encoding="utf-8", errors="replace"), headers)
    out = common.SNAPSHOTS / "llvm-opcodes.tsv" if args.refresh else args.output
    if out:
        common.write_tsv(out, rows, FIELDS)
        print(f"{len(rows)} opcodes -> {out}", file=sys.stderr)
    else:
        print("\t".join(FIELDS))
        for r in rows:
            print("\t".join(str(r[k]) for k in FIELDS))
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Shared helpers for the PTX catalog scripts: paths, TSV files, the catalog, opcode matching."""

from __future__ import annotations

import csv
import os
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "tests" / "corpus" / "catalog.yaml"
SNAPSHOTS = ROOT / "tools" / "catalog" / "snapshots"
EXCEPTIONS = ROOT / "tools" / "catalog" / "coverage-exceptions.yaml"
TABLE = ROOT / "spec" / "ptx-table.md"

FAMILIES = [
    "base", "Xkmsimt", "Xkmwarp", "Xkmbar", "Xkmscope", "Xkmmbar",
    "Xkmasync", "Xkmmma", "Xkmcluster", "Xkmmufu", "Xkmmisc",
]
KINDS = ["instruction", "modifier", "state-space", "special-register", "directive", "application"]
ROUTES = ["cuda", "builtin", "llvm-ir", "inline-asm"]
STATUSES = ["in-scope", "excluded"]


def sources_dir() -> Path:
    """Directory holding the downloaded manual and LLVM sources (see fetch_sources.sh)."""
    return Path(os.environ.get("KAMUI_SOURCES", ROOT / "build" / "catalog" / "sources"))


def manual_html() -> Path:
    return sources_dir() / "specs" / "ptx_isa_8.7.html"


def llvm_dir() -> Path:
    return sources_dir() / "llvm-20.1.8" / "llvm"


def read_tsv(path: Path) -> list[dict[str, str]]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def write_tsv(path: Path, rows: list[dict], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t", lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})


def load_catalog(path: Path = CATALOG) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    return data.get("features", [])


def load_exceptions(path: Path = EXCEPTIONS) -> list[dict]:
    if not path.exists():
        return []
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    return data.get("exceptions", []) or []


# Dot components that only name a type, a vector width or a size. They are dropped before an opcode is
# compared with a catalog row, so `shfl.sync.bfly.b32` is covered by the row `shfl.sync.bfly`.
_TYPE_RE = re.compile(
    r"^(?:[subf](?:8|16|32|64|128)(?:x[24])?|pred|bf16(?:x2)?|tf32|e4m3(?:x[24])?|e5m2(?:x[24])?"
    r"|e2m1(?:x[24])?|e2m3(?:x[24])?|e3m2(?:x[24])?|ue8m0(?:x2)?|v[248]|x[124]|[0-9]+)$"
)


def is_type_component(c: str) -> bool:
    return bool(_TYPE_RE.match(c))


def components(op: str) -> list[str]:
    """Split an opcode into dot components, keeping `::` inside a component (`shared::cta`)."""
    return [c for c in op.strip(".").split(".") if c]


def strip_types(op: str) -> list[str]:
    return [c for c in components(op) if not is_type_component(c)]


def covers(row_op: str, op: str) -> bool:
    """True when row_op is a prefix of op in whole dot components, after type components are dropped
    from op. A row component also matches an op component that extends it with `::` (`shared` matches
    `shared::cta`)."""
    r = strip_types(row_op)
    o = strip_types(op)
    if not r or len(r) > len(o):
        return False
    for a, b in zip(r, o):
        if a != b and not b.startswith(a + "::"):
            return False
    return True


def match_length(row: dict, op: str) -> int:
    """Number of dot components of the longest `opcodes` entry of row that covers op (0: none)."""
    return max((len(components(o)) for o in row.get("opcodes", []) or [] if covers(o, op)), default=0)


def covering_rows(op: str, rows: list[dict]) -> list[dict]:
    """Rows that cover op, the most specific first."""
    def exact(r: dict) -> bool:
        return any(strip_types(o) == strip_types(op) for o in r.get("opcodes", []) or [])

    cov = [r for r in rows if match_length(r, op)]
    return sorted(cov, key=lambda r: (not exact(r), -match_length(r, op)))

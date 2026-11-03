#!/usr/bin/env python3
"""Copy our litmus tests into the Dartagnan fork without their comments: deps/dat3m/litmus/PTX/Kamui/.

    python tools/dat3m/strip_tests.py            # write the copies
    python tools/dat3m/strip_tests.py --check    # fail if a copy is missing, stale or orphaned

The copies are tests/litmus/ptx/kamui/ (families, hand-written, PTX 8.7) and tests/litmus/ptx/imported/mixedproxy/
(the Dat3M tests are in the fork already, under litmus/PTX/). A copy keeps the name line, the initial state, the
threads and the condition, and drops the quoted comment between the name and the initial state, which in our
tests says which verdict the test expects and why. The fork's model is written from the PTX manual, and its tests
should not carry another model's answers.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "litmus"))
import litmus  # noqa: E402

SUITE = ROOT / "tests" / "litmus" / "ptx"
OUT = ROOT / "deps" / "dat3m" / "litmus" / "PTX" / "Kamui"
GROUPS = {"kamui": SUITE / "kamui", "mixedproxy": SUITE / "imported" / "mixedproxy"}


def strip(text: str) -> str:
    m = re.match(r"\s*(\S+)[ \t]+(\S+)[ \t]*\n", text)
    if not m:
        raise litmus.LitmusError("first line must be '<arch> <name>'")
    brace = litmus._find_brace(text, m.end())
    return f"{m.group(1)} {m.group(2)}\n{text[brace:].rstrip()}\n"


README = """# Kamui litmus tests

The PTX litmus tests of the kamui-isa project (https://github.com/lomolisso/kamui-isa, `tests/litmus/ptx/`),
copied without their comments by `tools/dat3m/strip_tests.py` there. Do not edit them here.

- `kamui/`: the project's own tests (generated families, hand-written tests, PTX 8.7 feature tests).
- `mixedproxy/`: tests translated from NVlabs/mixedproxy (BSD 3-Clause, `mixedproxy/LICENSE`).

The dialect (cluster placement, state spaces, mbarrier objects, granules and the other PTX 8.x forms) is described
in the kamui-isa repository, `tests/litmus/README.md`, section "The PTX 8.7 dialect".
"""


def copies() -> dict[Path, str]:
    out = {OUT / "README.md": README,
           OUT / "mixedproxy" / "LICENSE": (GROUPS["mixedproxy"] / "LICENSE").read_text()}
    for group, src in GROUPS.items():
        for p in sorted(src.rglob("*.litmus")):
            text = strip(p.read_text())
            litmus._parse(text)  # the copy must still be a valid test
            out[OUT / group / p.relative_to(src)] = text
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    want = copies()
    have = {p for p in OUT.rglob("*") if p.is_file()} if OUT.exists() else set()
    if a.check:
        bad = [p for p, t in want.items() if not p.exists() or p.read_text() != t] + sorted(have - set(want))
        for p in bad:
            print(f"stale, missing or orphaned: {p.relative_to(ROOT)}")
        print(f"{len(want)} files, {len(bad)} stale, missing or orphaned")
        return 1 if bad else 0
    for p in have - set(want):
        p.unlink()
    for p, t in want.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(t)
    print(f"wrote {len(want)} files to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

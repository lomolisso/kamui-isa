#!/usr/bin/env python3
"""List every feature named in the release notes of the PTX ISA 8.7 manual: the input of coverage check C.

Chapter 12 has one section per PTX version (2.0 to 8.7). The script reads every list item of every version
section and every code span in it, and classifies each mention:

- `special-register`: `%name`.
- `target`: `sm_*` (ignored by the check).
- `dot`: `.name`, a directive or a modifier (the check decides which).
- `opcode`: a lower-case word that looks like an instruction (`mbarrier.try_wait`).
- `other`: numbers, operand names (`byteMask`, `e`), anything else (ignored by the check).

The item text is not copied; `item` is the position of the list item inside its version section, so mentions
of the same item can be grouped. `adds` is 1 when the item announces a new instruction ("Adds support for ...
instruction", "A new instruction ...").

    python tools/catalog/release_notes.py              # print the TSV for the manual in $KAMUI_SOURCES
    python tools/catalog/release_notes.py --refresh    # rewrite tools/catalog/snapshots/release-notes.tsv
"""

from __future__ import annotations

import argparse
import html as htmllib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

FIELDS = ["version", "item", "adds", "mention", "kind"]

_OPCODE_RE = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+(?:::[a-z0-9_]+)*)*(?:::[a-z0-9_]+)*$")


def classify(mention: str) -> str:
    if mention.startswith("%"):
        return "special-register"
    if mention.startswith("sm_"):
        return "target"
    if re.match(r"^\.[A-Za-z_]", mention):
        return "dot"
    if _OPCODE_RE.match(mention) and len(mention) > 1:
        return "opcode"
    return "other"


def _split(code: str) -> list[str]:
    """One code span can hold several mentions (`{.u16x2, .s16x2}`, `mbarrier.arrive.expect_tx`)."""
    code = code.strip()
    if re.fullmatch(r"[0-9][\w.]*", code):
        return [code]
    if re.fullmatch(r"[%.]?[A-Za-z_][\w.:]*", code):
        return [code]
    return [t for t in re.findall(r"[%.]?[A-Za-z_][\w.:]*", code)] or [code]


def parse(html: str) -> list[dict]:
    start = html.find('<section id="release-notes">')
    end = html.find('<section id="descriptions-of-pragma-strings"', start)
    body = html[start:end if end > 0 else None]
    rows = []
    for part in re.split(r'<section id="changes-in-ptx-isa-version-', body)[1:]:
        version = part.split('"', 1)[0].replace("-", ".")
        for n, li in enumerate(re.findall(r"<li>(.*?)</li>", part, flags=re.S), start=1):
            text = re.sub(r"\s+", " ", htmllib.unescape(re.sub(r"<[^>]+>", " ", li)))
            adds = int(bool(re.search(r"(adds?|added) support for (the )?\S+( and \S+)? instructions?\b"
                                      r"|\ba new instruction\b|\bnew instructions?\b", text, flags=re.I)))
            seen = set()
            for code in re.findall(r'<span class="pre">([^<]+)</span>', li):
                for m in _split(htmllib.unescape(code)):
                    m = m.rstrip(".") if len(m) > 1 else m
                    if m in seen:
                        continue
                    seen.add(m)
                    rows.append({"version": version, "item": n, "adds": adds, "mention": m,
                                 "kind": classify(m)})
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--html", type=Path, default=None)
    ap.add_argument("--refresh", action="store_true", help="rewrite the committed snapshot")
    ap.add_argument("-o", "--output", type=Path)
    args = ap.parse_args(argv)
    rows = parse((args.html or common.manual_html()).read_text(encoding="utf-8"))
    out = common.SNAPSHOTS / "release-notes.tsv" if args.refresh else args.output
    if out:
        common.write_tsv(out, rows, FIELDS)
        print(f"{len(rows)} mentions -> {out}", file=sys.stderr)
    else:
        print("\t".join(FIELDS))
        for r in rows:
            print("\t".join(str(r[k]) for k in FIELDS))
    return 0


if __name__ == "__main__":
    sys.exit(main())

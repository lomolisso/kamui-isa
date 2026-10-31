#!/usr/bin/env python3
"""Extract the section tree of the PTX ISA 8.7 manual (single-page HTML) into a TSV.

One row per heading: section number, level, title, anchor. For sections that carry "PTX ISA Notes" and
"Target ISA Notes" paragraphs (chapters 5, 9, 10, 11), it also records two facts: the oldest PTX version the
notes name ("Introduced in PTX ISA version X") and the oldest target they name (`all` when the notes say
"supported on all target architectures"), and the set of `.name` tokens of its Syntax block (the
grammar vocabulary that check C compares release-note mentions with). No manual prose is copied.

    python tools/catalog/toc.py                 # print the TSV for the manual in $KAMUI_SOURCES
    python tools/catalog/toc.py --refresh       # rewrite tools/catalog/snapshots/sections.tsv
    python tools/catalog/toc.py --html <file>   # another copy of the manual
"""

from __future__ import annotations

import argparse
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

FIELDS = ["number", "level", "title", "anchor", "introduced_ptx", "min_target", "syntax_tokens"]


def _version_key(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split("."))


def _sm_key(t: str) -> int:
    return int(re.match(r"sm_(\d+)", t).group(1))


class _Parser(HTMLParser):
    """Walks the manual once. Keeps a stack of open <section> elements, reads headings, and collects the
    text of the list that follows a <strong>PTX ISA Notes</strong> or <strong>Target ISA Notes</strong>."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[dict] = []
        self.stack: list[dict] = []  # open sections: {"id", "row"}
        self.in_heading: str | None = None
        self.heading_text: list[str] = []
        self.in_strong = False
        self.strong_text: list[str] = []
        self.notes_kind: str | None = None  # "ptx" or "target" while inside the notes list
        self.notes_text: list[str] = []
        self.list_depth = 0
        self.in_syntax = False  # between <strong>Syntax</strong> and the next <strong> label
        self.in_pre = False
        self.pre_text: list[str] = []

    # -- helpers
    def _current(self) -> dict | None:
        for s in reversed(self.stack):
            if s["row"] is not None:
                return s["row"]
        return None

    def _flush_notes(self) -> None:
        if self.notes_kind is None:
            return
        row = self._current()
        text = " ".join(self.notes_text)
        if row is not None:
            row.setdefault("_" + self.notes_kind, []).append(text)
        self.notes_kind = None
        self.notes_text = []

    # -- events
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "section":
            self._flush_notes()
            self.stack.append({"id": a.get("id", ""), "row": None})
        elif re.fullmatch(r"h[1-6]", tag):
            self._flush_notes()
            self.in_heading = tag
            self.heading_text = []
        elif tag == "strong":
            self.in_strong = True
            self.strong_text = []
        elif tag in ("ul", "ol") and self.notes_kind is not None:
            self.list_depth += 1
        elif tag == "pre" and self.in_syntax:
            self.in_pre = True
            self.pre_text = []

    def handle_endtag(self, tag):
        if tag == "section":
            self._flush_notes()
            self.in_syntax = False
            if self.stack:
                self.stack.pop()
        elif tag == self.in_heading:
            text = re.sub(r"[\ue000-\uf8ff]", "", "".join(self.heading_text))  # the permalink icon
            text = re.sub(r"\s+", " ", text).strip()
            m = re.match(r"^((?:\d+\.)+)\s*(.*)$", text)
            if m and self.stack:
                row = {
                    "number": m.group(1).rstrip("."),
                    "level": int(self.in_heading[1]),
                    "title": m.group(2).strip(),
                    "anchor": self.stack[-1]["id"],
                }
                self.stack[-1]["row"] = row
                self.rows.append(row)
            self.in_heading = None
        elif tag == "strong":
            self.in_strong = False
            label = "".join(self.strong_text).strip()
            if label == "Syntax":
                self.in_syntax = True
            elif label in ("Description", "Semantics", "Notes", "PTX ISA Notes", "Target ISA Notes", "Examples"):
                self.in_syntax = False
            if label in ("PTX ISA Notes", "Target ISA Notes"):
                self._flush_notes()
                self.notes_kind = "ptx" if label.startswith("PTX") else "target"
                self.list_depth = 0
            elif self.notes_kind is not None and self.list_depth == 0:
                self._flush_notes()
        elif tag == "pre" and self.in_pre:
            self.in_pre = False
            row = self._current()
            if row is not None:
                row.setdefault("_syntax", []).append("".join(self.pre_text))
        elif tag in ("ul", "ol") and self.notes_kind is not None:
            self.list_depth -= 1
            if self.list_depth <= 0:
                self._flush_notes()

    def handle_data(self, data):
        if self.in_heading:
            self.heading_text.append(data)
        if self.in_strong:
            self.strong_text.append(data)
        if self.notes_kind is not None:
            self.notes_text.append(data)
        if self.in_pre:
            self.pre_text.append(data)


def summarize(row: dict) -> dict:
    """Turn the collected notes of one section into the two recorded facts."""
    ptx = " ".join(row.pop("_ptx", []))
    tgt = " ".join(row.pop("_target", []))
    versions = re.findall(r"introduced in PTX ISA (?:version )?(\d+\.\d+)", ptx, flags=re.I)
    row["introduced_ptx"] = min(versions, key=_version_key) if versions else ""
    tgt_flat = re.sub(r"\s+", " ", tgt)
    if re.search(r"supported on all target architectures", tgt_flat, flags=re.I):
        row["min_target"] = "all"
    else:
        sms = re.findall(r"sm_\d+[a-z]?", tgt_flat)
        row["min_target"] = min(sms, key=_sm_key) if sms else ""
    syntax = "\n".join(row.pop("_syntax", []))
    row["syntax"] = syntax
    row["syntax_tokens"] = " ".join(sorted(set(re.findall(r"\.[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)*", syntax))))
    return row


def first_syntax_line(row: dict) -> str:
    """The first non-empty, non-comment line of a section's Syntax block."""
    for line in row.get("syntax", "").splitlines():
        line = re.sub(r"\s*//.*$", "", line).strip()
        if line:
            return re.sub(r"\s+", " ", line)
    return ""


def parse(html: str) -> list[dict]:
    p = _Parser()
    p.feed(html)
    p.close()
    return [summarize(r) for r in p.rows]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--html", type=Path, default=None, help="manual HTML (default: $KAMUI_SOURCES copy)")
    ap.add_argument("--refresh", action="store_true", help="rewrite the committed snapshot")
    ap.add_argument("-o", "--output", type=Path, default=None, help="write the TSV to this file")
    args = ap.parse_args(argv)
    html_path = args.html or common.manual_html()
    rows = parse(html_path.read_text(encoding="utf-8"))
    out = common.SNAPSHOTS / "sections.tsv" if args.refresh else args.output
    if out:
        common.write_tsv(out, rows, FIELDS)
        print(f"{len(rows)} headings -> {out}", file=sys.stderr)
    else:
        w = sys.stdout
        w.write("\t".join(FIELDS) + "\n")
        for r in rows:
            w.write("\t".join(str(r.get(k, "")) for k in FIELDS) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

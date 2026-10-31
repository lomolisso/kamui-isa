#!/usr/bin/env python3
"""Check that the PTX feature catalog (tests/corpus/catalog.yaml) misses nothing.

NVIDIA publishes no machine-readable list of PTX instructions, so the catalog is checked against three sources
written independently of each other. Each check reads a snapshot in tools/catalog/snapshots/ (refreshed from
the real sources by toc.py, llvm_opcodes.py and release_notes.py with --refresh).

    python tools/catalog/check_coverage.py                    # A: the manual's own structure
    python tools/catalog/check_coverage.py --llvm             # B: every opcode clang 20 can print
    python tools/catalog/check_coverage.py --release-notes    # C: every feature named in the release notes
    python tools/catalog/check_coverage.py --validate         # the catalog's fields, order and corpus entries
    python tools/catalog/check_coverage.py --validate --require-entries   # also: every in-scope row has an entry

Check A: every instruction subsection of 9.7 (the ones with "PTX ISA Notes"), every special register of
chapter 10, every directive of chapter 11 and every state space of 5.1 has a catalog row.

Check B: every opcode in llvm-opcodes.tsv is covered by a row: one of the row's `opcodes` is a prefix of it in
whole dot components, after type and vector components (.b32, .u64, .f16x2, .v4, ...) are dropped.

Check C: every special register, directive, modifier and opcode named in the release notes matches a row.

Accepted mismatches of checks B and C are listed, each with a reason, in coverage-exceptions.yaml. A check fails
on an unmatched mention without an exception, and on an exception that no longer matches anything.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

REQUIRED = ["id", "kind", "ptx_syntax", "manual_section", "introduced_ptx", "min_target", "family", "tier",
            "status", "entry"]
OPTIONAL = ["opcodes", "route", "exclusion_reason", "tolerance_class", "notes"]
TOLERANCE_RE = re.compile(r"^(exact|ftz|reduction|ulp:\d+|property:[a-z_]+)$")
PENDING_LIMIT = 0.10


def section_number(row: dict) -> str:
    return (row.get("manual_section") or "").split(" ", 1)[0]


class Result:
    def __init__(self, name: str) -> None:
        self.name = name
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.info: dict = {}

    def ok(self) -> bool:
        return not self.errors

    def print(self, out=sys.stdout) -> None:
        for w in self.warnings:
            print(f"warning: {w}", file=out)
        for e in self.errors:
            print(f"error: {e}", file=out)
        summary = ", ".join(f"{k}={v if not isinstance(v, (list, dict)) else len(v)}" for k, v in self.info.items())
        print(f"{self.name}: {'ok' if self.ok() else 'FAILED'} ({summary})", file=out)


# ------------------------------------------------------------------ check A
def required_sections(sections: list[dict]) -> list[dict]:
    out = []
    for s in sections:
        n = s["number"]
        if n.startswith("9.7.") and (s["introduced_ptx"] or s["min_target"]):
            out.append(s)
        elif re.fullmatch(r"10\.\d+", n) or re.fullmatch(r"11\.\d+\.\d+", n) or re.fullmatch(r"5\.1\.\d+", n):
            out.append(s)
    return out


def check_manual(rows: list[dict], sections: list[dict]) -> Result:
    res = Result("check A (manual structure)")
    by_number = {s["number"]: s for s in sections}
    covered = defaultdict(list)
    for r in rows:
        n = section_number(r)
        if n:
            covered[n].append(r)
            s = by_number.get(n)
            if s is None:
                res.errors.append(f"{r['id']}: manual section {n} does not exist")
            elif r["manual_section"] != f"{n} {s['title']}":
                res.errors.append(f"{r['id']}: manual_section title differs from the manual: '{s['title']}'")
    need = required_sections(sections)
    matched = 0
    for s in need:
        if covered.get(s["number"]):
            matched += 1
        else:
            res.errors.append(f"no catalog row for {s['number']} {s['title']}")
    res.info = {"required": len(need), "matched": matched}
    return res


# ------------------------------------------------------------------ exceptions
def apply_exceptions(res: Result, check: str, unmatched: list[str], exceptions: list[dict]) -> None:
    mine = {e["mention"]: e for e in exceptions if e.get("check") == check}
    for e in mine.values():
        if not str(e.get("reason", "")).strip():
            res.errors.append(f"exception {check}:{e['mention']} has no reason")
    used = set()
    for m in unmatched:
        if m in mine:
            used.add(m)
        else:
            res.errors.append(f"{m}: not covered by any catalog row (add a row or an exception)")
    for m in mine:
        if m not in used:
            res.errors.append(f"stale exception {check}:{m}: it no longer matches an unmatched mention")
    res.info["exceptions"] = len(used)


# ------------------------------------------------------------------ check B
def check_llvm(rows: list[dict], opcodes: list[dict], exceptions: list[dict]) -> Result:
    res = Result("check B (clang 20 opcodes)")
    unmatched, excluded_only, matched = [], {}, 0
    for o in opcodes:
        op = o["opcode"]
        cov = common.covering_rows(op, rows)
        if not cov:
            unmatched.append(op)
            continue
        matched += 1
        if all(r["status"] == "excluded" for r in cov):
            excluded_only[op] = cov[0]["id"]
    apply_exceptions(res, "llvm", sorted(set(unmatched)), exceptions)
    res.info.update({"opcodes": len(opcodes), "matched": matched, "excluded_only": excluded_only})
    return res


# ------------------------------------------------------------------ check C
def directive_names(sections: list[dict]) -> set[str]:
    names = set()
    for s in sections:
        if re.fullmatch(r"11\.\d+\.\d+", s["number"]):
            for m in re.findall(r"\.[a-z_]+", s["title"]):
                names.add(m)
    return names


def instruction_names(sections: list[dict]) -> dict[str, list[str]]:
    """Instruction name -> numbers of the 9.7 sections whose title names it ("...: bar, barrier")."""
    names = defaultdict(list)
    for s in sections:
        if not s["number"].startswith("9.7.") or ": " not in s["title"]:
            continue
        for n in re.split(r"\s*[,/]\s*", s["title"].split(": ", 1)[1]):
            n = re.sub(r"\s*\(.*\)$", "", n).strip()
            if re.fullmatch(r"[a-z][a-z0-9_.:]*", n):
                names[n].append(s["number"])
    return names


def _related(a: str, b: str) -> bool:
    """One name is a prefix of the other in whole dot components."""
    ca, cb = common.components(a), common.components(b)
    k = min(len(ca), len(cb))
    return k > 0 and ca[:k] == cb[:k]


def _sreg_row(name: str, rows: list[dict]) -> dict | None:
    name = re.sub(r"[<\[].*$", "", name.lstrip("%"))
    name = re.sub(r"\.[xyzw]$", "", name)
    best = None
    for r in rows:
        if r["kind"] != "special-register":
            continue
        base = r["id"].split(".", 1)[1]
        if name == base or name.startswith(base):
            if best is None or len(base) > len(best["id"]):
                best = r
    return best


def _modifier_parts(mod: str) -> list[str]:
    """`.cas.b16` -> [`.cas`, `.b16`]; `::` stays attached (`.shared::cta`)."""
    return ["." + p for p in mod.strip(".").split(".") if p]


def _modifier_known(mod: str, texts: list[str], tokens: set[str]) -> bool:
    for part in _modifier_parts(mod):
        if part in tokens:
            continue
        if any(re.fullmatch(re.escape(part) + r"x[248]", t) for t in tokens):
            continue  # a format named by its packed forms: `.e4m3` in `.e4m3x2`
        if "::" in part:
            base, tail = part.split("::", 1)
            if base in tokens and any("::" + tail in t for t in texts):
                continue
        if any(re.search(re.escape(part) + r"(?![A-Za-z0-9_])", t) for t in texts):
            continue
        return False
    return True


def check_release_notes(rows: list[dict], notes: list[dict], sections: list[dict],
                        exceptions: list[dict]) -> Result:
    res = Result("check C (release notes)")
    by_number = {s["number"]: s for s in sections}
    rows_by_section = defaultdict(list)
    for r in rows:
        rows_by_section[section_number(r)].append(r)
    names = instruction_names(sections)
    roots = {common.components(n)[0] for n in names}
    dirs = directive_names(sections)
    all_tokens = set()
    for s in sections:
        all_tokens.update(s.get("syntax_tokens", "").split())
    all_texts = [r.get("ptx_syntax", "") for r in rows] + [r["id"] for r in rows]

    def opcode_ok(op: str) -> list[dict]:
        cov = common.covering_rows(op, rows)
        if cov:
            return cov
        # the name of a manual section (`match.sync`) whose rows carry more specific opcodes
        named = [r for num in names.get(op, []) for r in rows_by_section[num]]
        if named:
            return named
        # a family name such as `wmma` or `cp.async.bulk`: some row's opcode or id extends it
        return [r for r in rows if r["kind"] in ("instruction", "modifier")
                and any(_related(op, o) and len(common.components(o)) >= len(common.components(op))
                        for o in (r.get("opcodes") or []) + [r["id"]])]

    items = defaultdict(list)
    for n in notes:
        items[(n["version"], n["item"])].append(n)
    unmatched, counts, warnings, words = [], defaultdict(int), [], set()
    for (version, _item), mentions in items.items():
        ops = [m["mention"] for m in mentions
               if m["kind"] == "opcode" and common.components(m["mention"])[0] in roots]
        secs = set()
        for op in ops:
            secs.update(num for n, nums in names.items() if _related(n, op) for num in nums)
            secs.update(section_number(r) for r in opcode_ok(op))
        tokens, texts = set(), []
        for num in secs:
            if num in by_number:
                tokens.update(by_number[num].get("syntax_tokens", "").split())
            texts += [x for r in rows_by_section[num] for x in (r.get("ptx_syntax", ""), r["id"])]
        for m in mentions:
            kind, name = m["kind"], m["mention"]
            if kind == "opcode" and common.components(name)[0] not in roots:
                kind = "word"  # an operand or field name such as `mask` or `num_samples`
            if kind in ("target", "other", "word"):
                counts["ignored"] += 1
                if kind == "word":
                    words.add(name)
                continue
            if kind == "special-register":
                ok = _sreg_row(name, rows) is not None
            elif kind == "dot" and name in dirs:
                ok = any(r["id"] == "dir." + name[1:] for r in rows)
            elif kind == "dot":
                ok = (_modifier_known(name, texts, tokens) if secs else _modifier_known(name, all_texts, all_tokens))
                ok = ok or bool(common.covering_rows(name.lstrip("."), rows))  # `.mbarrier.test_wait`
            else:
                cov = opcode_ok(name)
                ok = bool(cov)
                if ok and m["adds"] == "1":
                    best = cov[0]
                    if best.get("introduced_ptx") and best["introduced_ptx"] != version:
                        warnings.append(f"{name}: release notes {version} add it, catalog row {best['id']} says "
                                        f"introduced_ptx {best['introduced_ptx']}")
            counts[kind] += 1
            if ok:
                counts["matched"] += 1
            else:
                unmatched.append(name)
    apply_exceptions(res, "release-notes", sorted(set(unmatched)), exceptions)
    res.warnings += sorted(set(warnings))
    res.info.update({"versions": len({v for v, _ in items}), "items": len(items), **counts,
                     "ignored_words": sorted(words)})
    return res


# ------------------------------------------------------------------ validation
def check_catalog(rows: list[dict], require_entries: bool = False, root: Path = common.ROOT) -> Result:
    res = Result("catalog validation")
    ids = [r.get("id", "") for r in rows]
    if ids != sorted(ids):
        res.errors.append("entries are not sorted by id")
    seen = set()
    for r in rows:
        rid = r.get("id", "<missing id>")
        if rid in seen:
            res.errors.append(f"{rid}: duplicate id")
        seen.add(rid)
        for k in REQUIRED:
            if k not in r:
                res.errors.append(f"{rid}: missing field {k}")
        for k in r:
            if k not in REQUIRED and k not in OPTIONAL:
                res.errors.append(f"{rid}: unknown field {k}")
        if rid != rid.lower() or " " in rid:
            res.errors.append(f"{rid}: ids are lower case without spaces")
        if r.get("kind") not in common.KINDS:
            res.errors.append(f"{rid}: kind must be one of {common.KINDS}")
        if r.get("family") not in common.FAMILIES:
            res.errors.append(f"{rid}: family must be one of {common.FAMILIES}")
        if r.get("tier") not in (1, 2, 3, 4):
            res.errors.append(f"{rid}: tier must be 1 to 4")
        if r.get("status") not in common.STATUSES:
            res.errors.append(f"{rid}: status must be one of {common.STATUSES}")
        if not isinstance(r.get("opcodes", []), list):
            res.errors.append(f"{rid}: opcodes must be a list")
        if r.get("kind") != "application" and not r.get("manual_section"):
            res.errors.append(f"{rid}: manual_section is required")
        if r.get("status") == "excluded":
            if not r.get("exclusion_reason"):
                res.errors.append(f"{rid}: excluded rows need an exclusion_reason")
            if r.get("entry"):
                res.errors.append(f"{rid}: excluded rows have no entry")
            continue
        if r.get("exclusion_reason"):
            res.errors.append(f"{rid}: exclusion_reason on an in-scope row")
        if r.get("route") not in common.ROUTES:
            res.errors.append(f"{rid}: route must be one of {common.ROUTES}")
        tol = r.get("tolerance_class", "")
        if not TOLERANCE_RE.match(str(tol)):
            res.errors.append(f"{rid}: tolerance_class '{tol}' is not exact, ftz, reduction, ulp:<n> or property:<name>")
        entry = r.get("entry") or ""
        if entry == "pending":
            if not r.get("notes"):
                res.errors.append(f"{rid}: a pending entry needs the reason in notes")
        elif entry:
            d = root / entry
            ey = d / "entry.yaml"
            if not ey.is_file():
                res.errors.append(f"{rid}: {entry}/entry.yaml does not exist")
            else:
                e = yaml.safe_load(ey.read_text(encoding="utf-8")) or {}
                if e.get("id") == rid and e.get("tolerance_class") != tol:
                    res.errors.append(f"{rid}: tolerance_class differs from {entry}/entry.yaml")
    in_scope = [r for r in rows if r.get("status") == "in-scope"]
    families = {r.get("family") for r in in_scope}
    for f in common.FAMILIES:
        if f not in families:
            res.errors.append(f"family {f} has no in-scope row")
    for a in ("app.vecadd", "app.shfl_reduce", "app.barrier", "app.atomics"):
        if a not in seen:
            res.errors.append(f"application row {a} is missing")
    pending = [r["id"] for r in in_scope if r.get("entry") == "pending"]
    missing = [r["id"] for r in in_scope if not r.get("entry")]
    if require_entries:
        for m in missing:
            res.errors.append(f"{m}: in-scope row without a corpus entry")
        if in_scope and len(pending) > PENDING_LIMIT * len(in_scope):
            res.errors.append(f"{len(pending)} pending entries, more than {PENDING_LIMIT:.0%} of {len(in_scope)}")
    res.info = {"rows": len(rows), "in_scope": len(in_scope), "excluded": len(rows) - len(in_scope),
                "with_entry": len(in_scope) - len(pending) - len(missing), "pending": len(pending),
                "without_entry": len(missing)}
    return res


# ------------------------------------------------------------------ main
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--llvm", action="store_true", help="check B")
    ap.add_argument("--release-notes", action="store_true", help="check C")
    ap.add_argument("--validate", action="store_true", help="check the catalog's fields and entries")
    ap.add_argument("--require-entries", action="store_true", help="with --validate: every in-scope row has an entry")
    ap.add_argument("--all", action="store_true", help="run A, B, C and --validate")
    ap.add_argument("--catalog", type=Path, default=common.CATALOG)
    ap.add_argument("--snapshots", type=Path, default=common.SNAPSHOTS)
    ap.add_argument("--exceptions", type=Path, default=common.EXCEPTIONS)
    args = ap.parse_args(argv)

    rows = common.load_catalog(args.catalog)
    exceptions = common.load_exceptions(args.exceptions)
    results = []
    run_a = args.all or not (args.llvm or args.release_notes or args.validate)
    if args.all or args.validate:
        results.append(check_catalog(rows, args.require_entries))
    if run_a or args.release_notes:
        sections = common.read_tsv(args.snapshots / "sections.tsv")
    if run_a:
        results.append(check_manual(rows, sections))
    if args.all or args.llvm:
        results.append(check_llvm(rows, common.read_tsv(args.snapshots / "llvm-opcodes.tsv"), exceptions))
    if args.all or args.release_notes:
        results.append(check_release_notes(rows, common.read_tsv(args.snapshots / "release-notes.tsv"), sections,
                                           exceptions))
    for r in results:
        r.print()
    return 0 if all(r.ok() for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())

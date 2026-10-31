#!/usr/bin/env python3
"""Print the tables that describe the PTX feature catalog and corpus, as Markdown.

    python tools/catalog/stats.py            # every table
    python tools/catalog/stats.py --nvcc     # also compare with nvcc's PTX (after build.py --all --nvcc)

Tables: rows per family, tier, status and route; the excluded features; the pending entries; the results of the
three coverage checks; the opcodes clang can print that the catalog excludes; features per PTX version; the
features the corpus reaches only through inline assembly or LLVM IR; the corpus entries; and, with --nvcc, the
opcodes on which nvcc's PTX and clang's PTX differ.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_coverage as cc  # noqa: E402
import common  # noqa: E402

TIERS = (1, 2, 3, 4)


def table(header: list[str], rows: list[list]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out) + "\n"


def by_family(rows: list[dict]) -> str:
    out = []
    for f in common.FAMILIES:
        fr = [r for r in rows if r["family"] == f]
        ins = [r for r in fr if r["status"] == "in-scope"]
        out.append([f"`{f}`"] + [sum(1 for r in ins if r["tier"] == t) for t in TIERS]
                   + [len(ins), len(fr) - len(ins), len(fr)])
    tot = [sum(c[k] for c in out) for k in range(1, 8)]
    out.append(["total", *tot])
    return table(["Family", "Tier 1", "Tier 2", "Tier 3", "Tier 4", "In scope", "Excluded", "Rows"], out)


def by_kind(rows: list[dict]) -> str:
    c = Counter((r["kind"], r["status"]) for r in rows)
    return table(["Kind", "In scope", "Excluded"],
                 [[k, c[(k, "in-scope")], c[(k, "excluded")]] for k in common.KINDS])


def route_by_tier(rows: list[dict]) -> str:
    ins = [r for r in rows if r["status"] == "in-scope"]
    out = []
    for t in TIERS:
        tr = [r for r in ins if r["tier"] == t]
        c = Counter(r.get("route") for r in tr)
        asm = c["inline-asm"] + c["llvm-ir"]
        out.append([t, *[c[x] for x in common.ROUTES], len(tr), f"{100 * asm / max(1, len(tr)):.0f}%"])
    return table(["Tier", *[f"`{x}`" for x in common.ROUTES], "Rows", "Not reachable from plain CUDA or builtins"], out)


def exclusions(rows: list[dict]) -> str:
    ex = [r for r in rows if r["status"] == "excluded"]
    reasons = Counter(r["exclusion_reason"] for r in ex)
    groups = defaultdict(list)
    for r in ex:
        groups[r["exclusion_reason"]].append(f"`{r['id']}`")
    return table(["Reason", "Rows", "Features"], [[k, v, ", ".join(groups[k])] for k, v in reasons.most_common()])


def pending(rows: list[dict]) -> str:
    return table(["Feature", "Reason"], [[f"`{r['id']}`", r.get("notes", "")] for r in rows if r.get("entry") == "pending"])


def coverage(rows: list[dict]) -> str:
    sections = common.read_tsv(common.SNAPSHOTS / "sections.tsv")
    exc = common.load_exceptions()
    a = cc.check_manual(rows, sections)
    b = cc.check_llvm(rows, common.read_tsv(common.SNAPSHOTS / "llvm-opcodes.tsv"), exc)
    c = cc.check_release_notes(rows, common.read_tsv(common.SNAPSHOTS / "release-notes.tsv"), sections, exc)
    t = table(["Check", "Source", "Mentions", "Matched", "Exceptions", "Result"], [
        ["A", "manual sections (9.7 instructions, chapter 10, chapter 11, 5.1)", a.info["required"], a.info["matched"], 0,
         "ok" if a.ok() else "FAILED"],
        ["B", "opcodes printed by the LLVM 20 NVPTX back end and clang's CUDA headers", b.info["opcodes"], b.info["matched"],
         b.info["exceptions"], "ok" if b.ok() else "FAILED"],
        ["C", "release notes, PTX 2.0 to 8.7", sum(c.info.get(k, 0) for k in ("opcode", "dot", "special-register")),
         c.info["matched"], c.info["exceptions"], "ok" if c.ok() else "FAILED"],
    ])
    t += "\nExceptions:\n\n" + table(["Check", "Mention", "Reason"],
                                     [[e["check"], f"`{e['mention']}`", " ".join(str(e["reason"]).split())] for e in exc])
    ex_only = Counter(b.info["excluded_only"].values())
    t += "\nOpcodes clang 20 can print that only excluded rows cover:\n\n" + table(
        ["Excluded row", "Opcodes"], [[f"`{k}`", v] for k, v in ex_only.most_common()])
    t += "\nRelease-note version warnings:\n\n" + ("\n".join(f"- {w}" for w in c.warnings) or "- none") + "\n"
    t += "\nRelease-note words that are not instructions (ignored): " + ", ".join(
        f"`{w}`" for w in c.info["ignored_words"]) + "\n"
    return t


def per_version(rows: list[dict]) -> str:
    ins = [r for r in rows if r["status"] == "in-scope" and r.get("introduced_ptx")]
    c = Counter(r["introduced_ptx"] for r in ins)
    vs = sorted(c, key=lambda v: tuple(int(x) for x in v.split(".")))
    return table(["Introduced in PTX", "In-scope rows"], [[v, c[v]] for v in vs])


def not_from_cuda(rows: list[dict]) -> str:
    out = []
    for f in common.FAMILIES:
        fr = [r for r in rows if r["status"] == "in-scope" and r["family"] == f and r.get("route") in ("inline-asm", "llvm-ir")]
        if fr:
            out.append([f"`{f}`", len(fr), ", ".join(f"`{r['id']}`" for r in sorted(fr, key=lambda r: r["id"]))])
    return table(["Family", "Rows", "Features (inline asm or LLVM IR only)"], out)


def corpus(rows: list[dict]) -> str:
    entries = sorted(common.ROOT.glob("tests/corpus/*/*/entry.yaml"))
    es = [yaml.safe_load(p.read_text()) for p in entries]
    ins = [r for r in rows if r["status"] == "in-scope"]
    own = sum(1 for r in ins if r.get("entry") and r["entry"] != "pending" and r["entry"].endswith("/" + r["id"].replace("::", ".")))
    shared = sum(1 for r in ins if r.get("entry") and r["entry"] != "pending") - own
    lang = Counter("LLVM IR" if (p.parent / "kernel.ll").exists() else "CUDA C++" for p in entries)
    tol = Counter(str(e["tolerance_class"]).split(":")[0] for e in es)
    t = table(["Quantity", "Value"], [
        ["entries (kernels)", len(es)], ["in-scope rows with their own entry", own], ["rows sharing another row's entry", shared],
        ["rows pending", sum(1 for r in ins if r.get("entry") == "pending")],
        ["entries in CUDA C++ / LLVM IR", f"{lang['CUDA C++']} / {lang['LLVM IR']}"],
        ["compile-only entries (run: false)", sum(1 for e in es if e.get("run") is False)],
        ["non-deterministic entries", sum(1 for e in es if e.get("deterministic") is False)],
        ["cluster launches", sum(1 for e in es if (e.get("launch") or {}).get("cluster"))],
        ["entries with a tensor map", sum(1 for e in es if any(p.get("kind") == "tensormap" for p in e["params"]))],
    ])
    t += "\nTolerance classes:\n\n" + table(["Class", "Entries"], [[f"`{k}`", v] for k, v in tol.most_common()])
    return t


def opcodes(ptx: str, roots: set[str]) -> Counter:
    """Instruction opcodes of a PTX file, type components dropped; operand lines of multi-line statements and
    words that are not instruction names are skipped."""
    c = Counter()
    for line in ptx.splitlines():
        line = re.sub(r"//.*$", "", line).strip()
        line = re.sub(r"^@!?%\w+\s+", "", line)
        m = re.match(r"([a-z][a-z0-9_]*(?:\.[\w:]+)*)(\s|;|$)", line)
        if not m or line.endswith(":") or m.group(1).split(".")[0] not in roots:
            continue
        c[".".join(common.strip_types(m.group(1)))] += 1
    return c


def nvcc_diff() -> str:
    clang_dir, nvcc_dir = common.ROOT / "tests" / "corpus", common.ROOT / "build" / "corpus-nvcc"
    roots = {common.components(k)[0] for k in cc.instruction_names(common.read_tsv(common.SNAPSHOTS / "sections.tsv"))}
    only_nvcc, only_clang, n = Counter(), Counter(), 0
    for p in sorted(nvcc_dir.glob("*/*/kernel.ptx")):
        rel = p.relative_to(nvcc_dir)
        cl = clang_dir / rel
        if not cl.exists():
            continue
        n += 1
        a, b = set(opcodes(cl.read_text(), roots)), set(opcodes(p.read_text(), roots))
        only_nvcc.update(b - a)
        only_clang.update(a - b)
    rows = [[f"`{k}`", v, ""] for k, v in only_nvcc.most_common(25)] + [[f"`{k}`", "", v] for k, v in only_clang.most_common(25)]
    return f"{n} entries compiled by both compilers.\n\n" + table(
        ["Opcode (types dropped)", "Entries where only nvcc emits it", "Entries where only clang emits it"], rows)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--nvcc", action="store_true", help="compare with build/corpus-nvcc (build.py --all --nvcc)")
    args = ap.parse_args(argv)
    rows = common.load_catalog()
    parts = [("Rows per family and tier", by_family(rows)), ("Rows per kind", by_kind(rows)),
             ("Route per tier", route_by_tier(rows)), ("Excluded features", exclusions(rows)),
             ("Pending entries", pending(rows)), ("Coverage checks", coverage(rows)),
             ("In-scope features per PTX version", per_version(rows)),
             ("Features that the corpus reaches only through inline asm or LLVM IR", not_from_cuda(rows)),
             ("Corpus", corpus(rows))]
    if args.nvcc:
        parts.append(("nvcc against clang", nvcc_diff()))
    for title, body in parts:
        print(f"### {title}\n\n{body}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

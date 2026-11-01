#!/usr/bin/env python3
"""Import the public PTX litmus tests into tests/litmus/ptx/imported/.

    python tools/litmus/import_tests.py [--dat3m /opt/dat3m] [--check]

Two groups are imported:

- **dat3m**: the 265 safety tests of Dat3M/Dartagnan (`litmus/PTX/{Manual,Nvidia,Memalloy,Barrier}`, the CADP
  folder holds liveness tests and is skipped), from the Dat3M tree in the dev container (tag 4.4.1). Each file
  is copied unchanged except for its final condition, which is rewritten as an `exists` condition (see
  `litmus.normalize`), and one duplicated test name. Dat3M's expected verdicts (`PTXv7_5-expected.csv`,
  `PTXv6_0-expected.csv`) are translated to allowed/forbidden of the rewritten condition.
- **mixedproxy**: the 11 templated tests of NVlabs/mixedproxy, vendored unchanged in
  `tests/litmus/ptx/imported/mixedproxy/src/`. Every template row is expanded and translated into the Dat3M
  dialect; the `permit`/`assert` annotation of each row gives its expected verdict.

Output: the `.litmus` files and `tests/litmus/ptx/imported/origin.csv` (one row per test: where it came from,
its licence, the original quantifier and the upstream verdicts). `--check` regenerates everything in memory and
fails if a committed file differs (needs the Dat3M tree, so it runs in the dev container).
"""

from __future__ import annotations

import argparse
import csv
import io
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import litmus  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "tests" / "litmus"
IMPORTED = SUITE / "ptx" / "imported"
ORIGIN = IMPORTED / "origin.csv"

DAT3M_TAG = "4.4.1"
DAT3M_COMMIT = "d8de5e8ef6aa4a697ff2bbe88fa8416dfcd4ac7c"
DAT3M_FOLDERS = ["Manual", "Manual/proxy", "Nvidia", "Nvidia/proxy", "Memalloy", "Barrier"]
MIXEDPROXY_COMMIT = "0807da29ac98d86a44179a65d430b78532e662b5"

ORIGIN_FIELDS = ["test", "source", "upstream", "upstream_ref", "licence", "quantifier",
                 "upstream_ptx_v7_5", "upstream_ptx_v6_0", "note"]

# Name clashes in the upstream files, fixed by naming the test after its file.
RENAMES = {"Manual/SB+sc-gpu-multiFence-TotalOrder.litmus": "SB+sc-gpu-multiFence-TotalOrder"}


def licence_of(rel: str) -> str:
    if rel.startswith("Nvidia/"):
        return "BSD-3-Clause (NVIDIA 2019)"
    return "CeCILL-B (Dat3M litmus/)"


def test_id(path: Path) -> str:
    return path.relative_to(SUITE).with_suffix("").as_posix()


def read_upstream_csv(path: Path) -> dict[str, bool]:
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        if line.strip():
            p, v = line.rsplit(",", 1)
            out[p.strip()] = v.strip() == "1"
    return out


# ----------------------------------------------------------------------------------------------- Dat3M


def dat3m_files(dat3m: Path) -> dict[Path, str]:
    """Map output path -> file text for the dat3m group (tests and licence/readme files)."""
    base = dat3m / "litmus" / "PTX"
    out: dict[Path, str] = {}
    dest = IMPORTED / "dat3m"
    out[dest / "LICENSE"] = (dat3m / "litmus" / "LICENSE").read_text()
    for extra in ["Nvidia/LICENSE", "Nvidia/README.md", "Memalloy/README.md"]:
        if (base / extra).exists():
            out[dest / extra] = (base / extra).read_text()
    return out


def import_dat3m(dat3m: Path) -> tuple[dict[Path, str], list[dict]]:
    base = dat3m / "litmus" / "PTX"
    res = dat3m / "dartagnan" / "src" / "test" / "resources"
    v75 = read_upstream_csv(res / "PTXv7_5-expected.csv")
    v60 = read_upstream_csv(res / "PTXv6_0-expected.csv")
    files = dat3m_files(dat3m)
    rows = []
    for folder in DAT3M_FOLDERS:
        for src in sorted((base / folder).glob("*.litmus")):
            rel = src.relative_to(base).as_posix()
            text = src.read_text(encoding="utf-8")
            note = []
            if rel in RENAMES:
                old = litmus.parse(text, src).name
                text = re.sub(rf"^(\s*PTX\s+){re.escape(old)}\b", rf"\g<1>{RENAMES[rel]}", text, count=1)
                note.append(f"renamed from {old} (name used twice upstream)")
            new, quant = litmus.normalize(text, src)
            dest = IMPORTED / "dat3m" / rel
            files[dest] = new
            up = f"litmus/PTX/{rel}"
            if quant == "forall":
                note.append("forall C rewritten as exists ~(C)")
            elif quant == "~exists":
                note.append("~exists C rewritten as exists C")
            rows.append({
                "test": test_id(dest), "source": "dat3m", "upstream": up,
                "upstream_ref": f"Dat3M {DAT3M_TAG} ({DAT3M_COMMIT[:7]})", "licence": licence_of(rel),
                "quantifier": quant,
                "upstream_ptx_v7_5": litmus.expected_from_quantifier(quant, v75[up]) if up in v75 else "",
                "upstream_ptx_v6_0": litmus.expected_from_quantifier(quant, v60[up]) if up in v60 else "",
                "note": "; ".join(note),
            })
    return files, rows


# ----------------------------------------------------------------------------------------------- mixedproxy


def expand_templates(text: str) -> list[str]:
    """Expand a mixedproxy test: text before `$$` is the template, each non-blank row after it fills $0..$n."""
    if "$$" not in text:
        return [text]
    tmpl, table = text.split("$$", 1)
    out = []
    for line in table.splitlines():
        if not line.strip():
            continue
        cells = [c.strip() for c in line.split("|")]
        body = tmpl
        for k in sorted(range(len(cells)), reverse=True):  # $10 before $1
            body = body.replace(f"${k}", cells[k])
        out.append(body)
    return out


_MP_ADDR = re.compile(r"\.(global|shared)\s+(\w+)(?:\s+physically\s+aliases\s+(\w+))?\s*;"
                      r"|\.(texref|surfref)\s+(\w+)\s+virtually\s+aliases\s+(\w+)\s*;")
_MP_THREAD = re.compile(r"d(\d+)\.b(\d+)\.t(\d+)\s*\{(.*?)\}", re.S)
_MP_CMD = re.compile(r"(permit|assert|check)\s*\((.*?)\)\s*as\s+\w+\s*;", re.S)


def translate_mixedproxy(text: str, name: str) -> tuple[str, str, str]:
    """Translate one expanded mixedproxy test. Returns (Dat3M text, expected verdict, note)."""
    notes = []
    head = text.split("d0.", 1)[0]
    init = []
    for m in _MP_ADDR.finditer(head):
        if m.group(1):
            init.append(f"{m.group(2)} @ generic aliases {m.group(3)}" if m.group(3) else f"{m.group(2)}=0")
        else:
            proxy = "texture" if m.group(4) == "texref" else "surface"
            init.append(f"{m.group(5)} @ {proxy} aliases {m.group(6)}")
    threads, constraints, reg_owner = [], [], {}
    for tid, m in enumerate(_MP_THREAD.finditer(text)):
        d, b, _t, body = m.groups()
        cells = []
        for raw in [s.strip() for s in body.split(";") if s.strip()]:
            cell, cons, reg = _mp_instr(raw, notes)
            cells.append(cell)
            if reg:
                if reg in reg_owner and reg_owner[reg] != tid:
                    raise litmus.LitmusError(f"{name}: register {reg} used by two threads")
                reg_owner[reg] = tid
                init.append(f"P{tid}:{reg}=0")
            if cons is not None:
                constraints.append(f"P{tid}:{reg} == {cons}")
        threads.append((f"P{tid}@cta {b},gpu {d}", cells))
    cm = _MP_CMD.search(text.split("}")[-1] if "}" in text else text)
    if not cm:
        raise litmus.LitmusError(f"{name}: no permit/assert")
    kind, cond = cm.group(1), _mp_condition(cm.group(2), reg_owner)
    pre = " /\\ ".join(constraints)
    if kind == "permit":
        final, expected = (f"{pre} /\\ ({cond})" if pre else cond), "allowed"
    elif kind == "assert":
        final, expected = (f"{pre} /\\ ~({cond})" if pre else f"~({cond})"), "forbidden"
    else:
        raise litmus.LitmusError(f"{name}: 'check' commands are not imported")
    t = litmus.Litmus(
        arch="PTX", name=name, comments=f'"Translated from NVlabs/mixedproxy ({kind} in the original)"',
        init=init, threads=[], quantifier="exists", cond_text=final, condition=None)
    for k, (place, cells) in enumerate(threads):
        _, cta, _, gpu = litmus._PLACE.fullmatch(place).groups()
        t.threads.append(litmus.Thread(k, int(cta), int(gpu), instrs=[litmus.parse_instr(c) for c in cells]))
    out = t.format()
    litmus.parse(out, name)
    return out, expected, "; ".join(dict.fromkeys(notes))


def _mp_instr(raw: str, notes: list[str]) -> tuple[str, str | None, str | None]:
    raw = " ".join(raw.split())
    m = re.fullmatch(r"fence\.alias", raw)
    if m:
        return "fence.proxy.alias", None, None
    if raw.startswith("fence.proxy."):
        kinds = raw.split(".")[2:]
        if len(kinds) != 1:
            raise litmus.LitmusError(f"multi-proxy fence not supported: {raw}")
        return raw, None, None
    if raw.startswith("fence."):
        return raw, None, None
    m = re.fullmatch(r"(ld|tld|suld|ldc|st|sust|atom|suatom|red|sured)((?:\.\w+)*)\s+(.*)", raw)
    if not m:
        raise litmus.LitmusError(f"cannot translate mixedproxy instruction {raw!r}")
    op, quals, rest = m.group(1), [q for q in m.group(2).split(".") if q], m.group(3)
    cons = None
    cm = re.search(r"==\s*(-?\d+)\s*$", rest)
    if cm:
        cons, rest = cm.group(1), rest[:cm.start()].strip()
    args = [a.strip().strip("[]") for a in rest.split(",")]
    aop = None
    if op in ("atom", "suatom", "red", "sured"):
        aop = quals.pop(0)
    sem = next((q for q in quals if q in litmus.ORDERINGS), "weak")
    scope = next((q for q in quals if q in ("cta", "gpu", "sys")), None)
    if sem == "volatile":
        notes.append("volatile translated as relaxed.sys (PTX ISA 8.7 section 8.4.2)")
        sem, scope = "relaxed", "sys"
    if sem != "weak" and scope is None:
        scope = "gpu"
    q = f".{sem}" + (f".{scope}" if scope and sem != "weak" else "")
    dop = {"ldc": "cold"}.get(op, op)
    if op in ("ld", "tld", "suld", "ldc"):
        return f"{dop}{q} {args[0]}, {args[1]}", cons, args[0]
    if op in ("st", "sust"):
        return f"{dop}{q} {args[0]}, {args[1]}", None, None
    if op in ("atom", "suatom"):
        return f"{dop}{q}.{aop} {args[0]}, {args[1]}, {args[2]}", cons, args[0]
    return f"{dop}{q}.{aop} {args[0]}, {args[1]}", None, None


def _mp_condition(text: str, reg_owner: dict[str, int]) -> str:
    text = " ".join(text.split())
    text = text.replace("&&", "/\\").replace("||", "\\/")
    text = re.sub(r"\bnot\b", "~", text)

    def reg(m):
        r = m.group(0)
        if r not in reg_owner:
            raise litmus.LitmusError(f"register {r} is not written by any thread")
        return f"P{reg_owner[r]}:{r}"

    return re.sub(r"\br\d+\b", reg, text)


def import_mixedproxy() -> tuple[dict[Path, str], list[dict]]:
    src = IMPORTED / "mixedproxy" / "src"
    files, rows = {}, []
    for f in sorted(src.glob("*.test")):
        variants = expand_templates(f.read_text())
        for k, body in enumerate(variants):
            name = f.stem if len(variants) == 1 else f"{f.stem}+{k:02d}"
            text, expected, note = translate_mixedproxy(body, name)
            dest = IMPORTED / "mixedproxy" / f"{name}.litmus"
            files[dest] = text
            rows.append({
                "test": test_id(dest), "source": "mixedproxy", "upstream": f"tests/{f.name}" + (
                    f" row {k}" if len(variants) > 1 else ""),
                "upstream_ref": f"NVlabs/mixedproxy {MIXEDPROXY_COMMIT[:7]}", "licence": "BSD-3-Clause (NVIDIA)",
                "quantifier": "exists", "upstream_ptx_v7_5": expected, "upstream_ptx_v6_0": "", "note": note,
            })
    return files, rows


# ----------------------------------------------------------------------------------------------- main


def build(dat3m: Path) -> dict[Path, str]:
    files, rows = import_dat3m(dat3m)
    f2, r2 = import_mixedproxy()
    files.update(f2)
    rows += r2
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=ORIGIN_FIELDS, lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
    files[ORIGIN] = buf.getvalue()
    return files


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dat3m", type=Path, default=Path("/opt/dat3m"), help="Dat3M source tree (tag 4.4.1)")
    ap.add_argument("--check", action="store_true", help="compare with the committed files instead of writing")
    a = ap.parse_args()
    files = build(a.dat3m)
    if a.check:
        bad = [p for p, t in files.items() if not p.exists() or p.read_text(encoding="utf-8") != t]
        committed = {p for p in (IMPORTED / "dat3m").rglob("*") if p.is_file()} | set(
            (IMPORTED / "mixedproxy").glob("*.litmus"))
        extra = sorted(committed - set(files))
        for p in bad:
            print(f"differs: {p.relative_to(ROOT)}")
        for p in extra:
            print(f"not generated: {p.relative_to(ROOT)}")
        print(f"{len(files)} files, {len(bad)} differ, {len(extra)} extra")
        return 1 if bad or extra else 0
    for p, t in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(t, encoding="utf-8")
    n = sum(1 for p in files if p.suffix == ".litmus")
    print(f"wrote {n} tests and {ORIGIN.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

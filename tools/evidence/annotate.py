"""Find the SASS that implements each catalog row and write evidence/sass-observations.csv.

How a row is matched (all inputs are files: kernel.ptx, the nvdisasm JSON in build/evidence/json/, the ptxas
and cuobjdump text in evidence/):

1. The PTX of interest: the instructions in the entry's kernel.ptx whose opcode is covered by one of the row's
   `opcodes` (the catalog rule: a prefix in whole dot components, types dropped). When none is covered, the
   entry's `expect_ptx` patterns are used instead.
2. The SASS class: for each such PTX opcode, the longest key of sass_classes.yaml that covers it gives a list
   of SASS opcode patterns. Special registers and state spaces have their own tables.
3. The anchors: every SASS instruction of the entry (all functions, including called subroutines) whose opcode
   matches a pattern, except the instructions every kernel has (thread index, parameter loads, bounds check,
   address arithmetic). For rows about a memory modifier (scope, ordering, cache operator), instructions that
   carry extra SASS modifiers are kept and plain ones dropped when both appear.
4. The hidden mechanisms: SASS instructions in and around the anchors that the PTX did not ask for
   (convergence barriers, memory barriers, cache invalidations, scoreboard waits, warp aggregation, ...).

A row is flagged for a human look when its PTX is missing, no class covers it, or no anchor is found. The
review decisions are kept in sass-review.yaml and override the computed fields.
"""

from __future__ import annotations

import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path

import yaml

import common
import sass as S

HERE = Path(__file__).resolve().parent
CLASSES_FILE = HERE / "sass_classes.yaml"
REVIEW_FILE = HERE / "sass-review.yaml"

COLUMNS = ["feature_id", "family", "tier", "kind", "entry", "ptx_instr", "ptx_count", "sass_sequence", "sass_len",
           "sass_per_ptx", "modifiers_encoding", "hidden_mechanism", "regs", "shared_bytes", "shared_bytes_resusage",
           "jit_matches_offline", "status", "notes"]
MECHANISMS = ["none", "convergence-barrier", "uniform-datapath", "warp-aggregation", "elect-loop",
              "memory-barrier", "cache-maintenance", "scoreboard", "syncs-unit", "descriptor", "cga",
              "constant-bank", "software-sequence", "other"]
STATUSES = ["auto", "reviewed", "flagged", "pending"]
# PTX modifier components that make a row "about a modifier" of a memory instruction.
MEMORY_MODIFIERS = {"cta", "cluster", "gpu", "sys", "relaxed", "acquire", "release", "acq_rel", "sc", "mmio",
                    "volatile", "ca", "cg", "cs", "lu", "cv", "wb", "wt", "nc", "weak"}
# Plain forms of memory instructions, as in every kernel's own loads and stores.
PLAIN = {"LDG.E", "STG.E", "LDG.E.64", "STG.E.64", "LDG.E.128", "STG.E.128", "LDS", "STS", "LDS.64", "STS.64",
         "LD.E", "ST.E", "LD.E.64", "ST.E.64"}
SCOPE_TOKENS = {"cta": ["STRONG.SM", ".CTA"], "cluster": ["STRONG.GPU", ".GPU", "STRONG.SM", ".CTA"],
                "gpu": ["STRONG.GPU", ".GPU"], "sys": ["STRONG.SYS", ".SYS"]}
WINDOW = 3
SPACES = {"global", "shared", "local", "const", "param"}
MAX_LIST = 12


@dataclass
class Insn:
    fn: str
    idx: int
    pred: str
    opcode: str
    operands: str

    def text(self) -> str:
        return f"{self.pred} {self.opcode}".strip()


# ---------------------------------------------------------------- inputs

def load_classes(path: Path = CLASSES_FILE) -> dict:
    return yaml.safe_load(path.read_text())


def load_review(path: Path = REVIEW_FILE) -> dict:
    if not path.exists():
        return {}
    return yaml.safe_load(path.read_text()) or {}


def sass_functions(functions: list[dict]) -> list[list[Insn]]:
    """nvdisasm -json functions to lists of instructions, NOPs dropped."""
    out = []
    for f in functions:
        name = f["function-name"]
        insns = [Insn(name, i, ins.get("predicate", ""), ins["opcode"], ins.get("operands", ""))
                 for i, ins in enumerate(f["sass-instructions"]) if ins["opcode"] != "NOP"]
        out.append(insns)
    return out


def ptx_statements(ptx: str) -> list[tuple[str, str]]:
    """(opcode, statement text with its guard predicate) of every instruction statement of a PTX file."""
    out = []
    for line in ptx.splitlines():
        line = re.sub(r"//.*$", "", line).strip()
        for stmt in line.split(";"):
            stmt = stmt.strip()
            bare = re.sub(r"^@!?%\w+\s+", "", stmt)
            m = re.match(r"([a-z][a-z0-9_]*(?:\.[\w:]+)*)(\s|$)", bare)
            if m and not bare.endswith(":"):
                out.append((m.group(1), stmt))
    return out


def ptx_instructions(ptx: str) -> list[str]:
    """Opcodes of the instruction statements of a PTX file, in order."""
    return [op for op, _ in ptx_statements(ptx)]


def ptxas_numbers(text: str) -> tuple[str, str]:
    """Registers and shared memory of the entry function from ptxas -v output."""
    m = re.search(r"Compiling entry function '[^']+'.*?Used (\d+) registers", text, re.S)
    regs = m.group(1) if m else ""
    m = re.search(r"Compiling entry function '[^']+'.*?(\d+) bytes smem", text, re.S)
    return regs, (m.group(1) if m else "0")


def resusage_shared(text: str) -> str:
    m = re.search(r"Function \S+:\s*\n\s*REG:\d+ STACK:\d+ SHARED:(\d+)", text)
    return m.group(1) if m else ""


# ---------------------------------------------------------------- matching

def harness(fn: list[Insn], keep_params: bool = False, keep_exit: bool = False) -> set[int]:
    """Indices of the instructions every kernel has: thread and block index, the global index, parameter and
    descriptor loads, the bounds check and its exit, address scaling, the final exit and the trailing loop."""
    out = set()
    first_isetp = next((k for k, i in enumerate(fn) if i.opcode.startswith("ISETP")), len(fn))
    seen_index_imad = False
    for k, i in enumerate(fn):
        op, ops = i.opcode, i.operands
        if op in ("S2R", "S2UR") and re.search(r"SR_(TID|CTAID)\.X$", ops):
            out.add(k)
        elif op.startswith(("LDC", "ULDC")) and not keep_params:
            m = re.search(r"c\[0x0\]\[(0x[0-9a-f]+|RZ)\]", ops)
            if m and (m.group(1) in ("RZ", "0x28", "0x208") or int(m.group(1), 16) >= 0x210):
                out.add(k)
        elif op == "IMAD" and not seen_index_imad and k < first_isetp and "UR" in ops:
            out.add(k)
            seen_index_imad = True
        elif op.startswith("IMAD.WIDE") and re.search(r",0x(1|2|4|8|10|20|40|80)?,R\w+$", ops):
            out.add(k)
        elif (op == "EXIT" and not keep_exit) or (op == "BRA" and k == len(fn) - 1):
            out.add(k)
        elif op.startswith("HFMA2.MMA") and re.match(r"R\w+,-RZ,RZ,", ops):
            out.add(k)
        elif op.startswith("ISETP") and k + 1 < len(fn) and fn[k + 1].opcode == "EXIT" and fn[k + 1].pred:
            out.add(k)
    return out


def class_patterns(ops: list[str], classes: dict) -> tuple[list[str], list[str]]:
    """The SASS patterns for a list of PTX opcodes, and the class keys used."""
    keys, pats = [], []
    table = classes["classes"]
    for op in ops:
        comps = common.strip_types(op)
        space = next((c for c in comps[1:] if c.split("::")[0] in SPACES), None)
        spaced = f"{comps[0]}.{space}" if space else None
        if spaced and spaced not in table and space.startswith("shared::cta"):
            spaced = f"{comps[0]}.shared"
        best = max((k for k in table if common.covers(k, op)), key=lambda k: len(common.strip_types(k)),
                   default=None)
        generic = best in ("ld", "st") or (best and len(best.split(".")) == 2 and
                                           best.split(".")[1].split("::")[0] in SPACES)
        if generic and spaced in table:
            best = spaced
        if best and best not in keys:
            keys.append(best)
            pats += [p for p in table[best] if p not in pats]
    return pats, keys


def matches(pats: list[str], i: Insn) -> bool:
    """`OPCODE` matches the start of the opcode; `OPCODE@regex` also needs the operands to contain regex."""
    for p in pats:
        opc, _, operand = p.partition("@")
        if re.match(rf"(?:{opc})(\.|$)", i.opcode) and (not operand or re.search(operand, i.operands)):
            return True
    return False


def is_sreg_read(i: Insn) -> bool:
    if i.opcode in ("S2R", "S2UR", "CS2R", "CS2R.32") and "SR_" in i.operands:
        return True
    if i.opcode.startswith(("LDC", "ULDC")):
        m = re.search(r"c\[0x0\]\[(0x[0-9a-f]+)\]", i.operands)
        return bool(m) and int(m.group(1), 16) < 0x208 and m.group(1) != "0x28"
    return False


def mechanisms(funcs: list[list[Insn]], anchors: list[Insn], ptx_ops: list[str], emulated: bool) -> list[str]:
    found = []
    if not anchors:
        return ["none"]
    roots = {o.split(".")[0] for o in ptx_ops}
    by_fn = {}
    for a in anchors:
        by_fn.setdefault(a.fn, []).append(a.idx)
    region: list[Insn] = []
    enclosed = False
    for fn in funcs:
        if not fn or fn[0].fn not in by_fn:
            continue
        idxs = by_fn[fn[0].fn]
        pos = {i.idx: k for k, i in enumerate(fn)}
        lo, hi = min(pos[x] for x in idxs), max(pos[x] for x in idxs)
        region += fn[max(0, lo - WINDOW): hi + WINDOW + 1]
        stack = []
        for k, i in enumerate(fn):
            if i.opcode == "BSSY":
                stack.append(k)
            elif i.opcode == "BSYNC" and stack:
                b = stack.pop()
                if any(b < pos[x] < k for x in idxs):
                    enclosed = True
    ops = [i.opcode for i in region]
    text = " ".join(f"{i.opcode} {i.operands}" for i in region)
    if enclosed or any(o.startswith("WARPSYNC") for o in ops):
        found.append("convergence-barrier")
    if any(a.opcode.startswith("U") or a.opcode == "S2UR" or
           re.search(r"\bU[RP]\d", re.sub(r"(?<![a-z])desc\[UR\d+\]", "", a.operands)) for a in anchors):
        found.append("uniform-datapath")
    if roots & {"atom", "red"} and any(a.opcode.startswith(("ATOM", "RED")) for a in anchors):
        fn_ops = [i.opcode for fn in funcs for i in fn]
        if any(o.startswith(("VOTE.ANY", "VOTEU.ANY")) for o in fn_ops) and \
                any(o.startswith(("UFLO", "FLO", "POPC", "SHFL.IDX", "REDUX")) for o in fn_ops):
            found.append("warp-aggregation")
    if any(o.startswith("ELECT") for o in ops) and any(o.startswith("BRA.U.ANY") for o in ops):
        found.append("elect-loop")
    if any(o.startswith(("MEMBAR", "ERRBAR", "CGAERRBAR", "FENCE.VIEW")) for o in ops):
        found.append("memory-barrier")
    if any(o.startswith("CCTL") for o in ops):
        found.append("cache-maintenance")
    if any(o.startswith(("DEPBAR", "LDGDEPBAR", "WARPGROUP.DEPBAR", "ARRIVES.LDGSTSBAR")) for o in ops):
        found.append("scoreboard")
    if any(o.startswith("SYNCS") for o in ops):
        found.append("syncs-unit")
    if any("gdesc[" in a.operands or a.opcode.startswith("UTMA") for a in anchors):
        found.append("descriptor")
    if any(o.startswith("UCGABAR") for o in ops) or "SR_CgaCtaId" in text:
        found.append("cga")
    if any(a.opcode.startswith(("LDC", "ULDC")) for a in anchors) and any(o.startswith("sreg") for o in ptx_ops):
        found.append("constant-bank")
    if any(o.startswith("CALL.REL") for o in ops) or len({a.fn for a in anchors}) > 1 or emulated:
        found.append("software-sequence")
    return found or ["none"]


def modifier_encoding(ptx_ops: list[str], anchors: list[Insn], region_ops: list[str]) -> str:
    """How each PTX modifier of interest shows up in the SASS of the anchors."""
    out = []
    a_ops = [a.opcode for a in anchors]
    toks = {t for o in a_ops for t in o.split(".")[1:]}
    comps = []
    for op in ptx_ops:
        for c in common.strip_types(op)[1:]:
            if c not in comps:
                comps.append(c)
    for c in comps:
        base = c.split("::")[0]
        if base in SCOPE_TOKENS:
            hit = {t for o in a_ops + region_ops for t in SCOPE_TOKENS[base] if t in o}
            hit = sorted(t for t in hit if not any(t != u and t in u for u in hit))
            out.append(f".{c} -> {'/'.join(hit) if hit else 'no scope bits'}")
        elif base == "acquire":
            out.append(".acquire -> " + ("CCTL.IVALL after" if any(o.startswith("CCTL.IVALL") for o in region_ops)
                                         else "no extra instruction"))
        elif base == "release":
            out.append(".release -> " + ("MEMBAR before" if any(o.startswith("MEMBAR") for o in region_ops)
                                         else "no extra instruction"))
        elif base == "acq_rel":
            out.append(".acq_rel -> MEMBAR before + CCTL.IVALL after" if any(o.startswith("MEMBAR") for o in region_ops)
                       else ".acq_rel -> no extra instruction")
        elif base == "sc":
            hit = sorted({o for o in region_ops if o.startswith("MEMBAR.SC")})
            out.append(f".sc -> {'/'.join(hit) if hit else 'no MEMBAR.SC'}")
        elif base in ("rn", "rz", "rm", "rp", "rni", "rzi", "rmi", "rpi"):
            want = {"rn": "RN", "rz": "RZ", "rm": "RM", "rp": "RP", "rni": "ROUND", "rzi": "TRUNC", "rmi": "FLOOR",
                    "rpi": "CEIL"}[base]
            out.append(f".{c} -> {'.' + want if want in toks else 'default rounding (no modifier)'}")
        elif base in ("ftz", "sat", "approx", "relu", "nan", "satfinite", "mmio"):
            want = {"approx": "MUFU"}.get(base, base.upper())
            hit = want in toks or any(o.startswith(want) for o in a_ops)
            out.append(f".{c} -> {'.' + want if hit else 'not visible'}")
        elif base in ("global", "shared", "local", "const", "param"):
            hit = sorted({o.split(".")[0] for o in a_ops if o.split(".")[0] in
                          ("LDG", "STG", "ATOMG", "REDG", "LDS", "STS", "ATOMS", "LDL", "STL", "LDC", "ULDC",
                           "LD", "ST", "ATOM", "RED")})
            if hit:
                out.append(f".{c} -> {'/'.join(hit)}")
    return "; ".join(out)


def short(items: list[str]) -> str:
    uniq = list(dict.fromkeys(items))
    s = "; ".join(uniq[:MAX_LIST])
    return s + (f"; ... (+{len(uniq) - MAX_LIST})" if len(uniq) > MAX_LIST else "")


def annotate_row(row: dict, classes: dict, build: Path = S.BUILD) -> dict:
    """One CSV row for one in-scope catalog row with an entry."""
    d = common.ROOT / row["entry"]
    eid = d.name
    e = yaml.safe_load((d / "entry.yaml").read_text())
    ptx = (d / "kernel.ptx").read_text()
    funcs = sass_functions(S.load_json(eid, build))
    regs, smem = ptxas_numbers((S.PTXAS_DIR / f"{eid}.txt").read_text())
    rec = {c: "" for c in COLUMNS}
    rec.update(feature_id=row["id"], family=row["family"], tier=row["tier"], kind=row["kind"], entry=eid, regs=regs,
               shared_bytes=smem, shared_bytes_resusage=resusage_shared((S.SASS_DIR / f"{eid}.sass").read_text()))
    flags: list[str] = []
    kind = row["kind"]
    param_rows = ("ld.param", "space.param", "st.param", "dir.ptr")
    stmts = [(o, t) for o, t in ptx_statements(ptx)
             if row["id"] in param_rows or not re.match(
                 r"(ld|st)\.param\.\S+\s+(%\w+,\s*)?\[(\w+_param_\d+|param\d+|retval\d+|func_retval\d+)\]", t)]
    ops = [o for o, _ in stmts]
    keep_params = keep_exit = False
    if row["id"] == "space.sreg":
        kind = "special-register"
    if kind == "directive":
        name = row["id"].split(".", 1)[1]
        lines = [ln.strip() for ln in ptx.splitlines() if re.search(rf"(^|\s)(\.|@@){re.escape(name)}\b", ln)]
        rec.update(ptx_instr=short(lines[:3]), ptx_count=len(lines), sass_len=0, hidden_mechanism="none",
                   notes="directive: no SASS instruction of its own; its effect shows in the ptxas output or the "
                         "cubin's attributes")
        if not lines:
            flags.append("no-ptx")
        return finish(rec, flags)
    if kind == "application":
        anchors = [i for fn in funcs for k, i in enumerate(fn) if k not in harness(fn)]
        mine = ops
        pats: list[str] = []
    elif kind == "special-register":
        name = row["id"].split(".", 1)[1]
        mine = [o for o in ops if o.startswith(("mov", "cvt"))]
        rec["ptx_instr"] = ".sreg (all special registers)" if row["id"] == "space.sreg" else f"%{name}"
        srs = classes["sregs"].get(row["id"])
        anchors = []
        for fn in funcs:
            h = harness(fn) if row["id"] not in ("sreg.tid", "sreg.ctaid", "space.sreg") else set()
            for k, i in enumerate(fn):
                if k in h or not is_sreg_read(i):
                    continue
                if srs is None or any(s in i.operands for s in srs):
                    anchors.append(i)
        if row["id"] in ("sreg.ntid", "sreg.nctaid"):
            anchors = [i for fn in funcs for i in fn if i.opcode.startswith(("LDC", "ULDC")) and
                       re.search(r"c\[0x0\]\[(RZ|0x[0-9a-f]?[0-9a-f])\]", i.operands)]
        pats = []
    else:
        if kind == "state-space":
            pats = classes["spaces"].get(row["id"], [])
            mine = [o for o in ops if any(c == row["id"].split(".", 1)[1] or c.startswith(row["id"].split(".", 1)[1] + "::")
                                          for c in common.components(o)[1:])]
            keep_params = row["id"] in ("space.param", "space.const")
            if row["id"] == "space.reg":
                rec.update(ptx_instr=".reg", ptx_count=0, sass_len=0, hidden_mechanism="none",
                           notes="registers: no instruction of their own")
                return finish(rec, flags)
        else:
            mine = [o for o in ops if any(common.covers(x, o) for x in (row.get("opcodes") or []))]
            if not mine:
                regs_ = [re.compile(p) for p in e.get("expect_ptx") or []]
                mine = [o for o, text in stmts if any(r.search(text) for r in regs_)]
                if mine:
                    rec["notes"] = "PTX found through the entry's expect_ptx patterns"
            if not mine:
                flags.append("no-ptx")
            pats, keys = class_patterns(mine, classes)
            keep_params = any(k in ("ld.param", "st.param", "ld.const") for k in keys)
            keep_exit = "exit" in keys
            if mine and not pats:
                flags.append("no-class")
        anchors = []
        for fn in funcs:
            h = harness(fn, keep_params, keep_exit)
            anchors += [i for k, i in enumerate(fn) if k not in h and matches(pats, i)]
        comps = {c for o in mine for c in common.strip_types(o)[1:]}
        if kind in ("modifier", "state-space") and comps & MEMORY_MODIFIERS:
            fancy = [a for a in anchors if a.opcode not in PLAIN]
            if fancy and len(fancy) < len(anchors):
                anchors = fancy
    if not anchors and kind != "application":
        flags.append("no-sass")
    if kind == "special-register":
        name = row["id"].split(".", 1)[1]
        pat = r"%(tid|ntid|ctaid|nctaid|laneid|warpid|smid|clock\w*|globaltimer\w*|lanemask_\w+)\b" \
            if row["id"] == "space.sreg" else rf"%{re.escape(name)}(?![\w])"
        reads = len(re.findall(pat, ptx))
        n = max(1, reads)
        rec.update(ptx_count=reads)
    else:
        n = max(1, len(mine))
        rec.update(ptx_count=len(mine) if kind != "application" else len(ops))
    if not rec["ptx_instr"]:
        rec["ptx_instr"] = short(mine) if kind != "application" else f"{len(ops)} PTX instructions"
    rec["sass_sequence"] = short([a.text() for a in anchors]) if kind != "application" else \
        short([a.opcode for a in anchors])
    rec["sass_len"] = len(anchors)
    per = len(anchors) / n
    rec["sass_per_ptx"] = f"{per:.2f}" if kind != "application" else ""
    region_ops = region_opcodes(funcs, anchors)
    emu = classes.get("emulated", {}).get(row["id"])
    rec["hidden_mechanism"] = ";".join(mechanisms(funcs, anchors, mine if kind != "special-register" else
                                                  ["sreg"], bool(emu)))
    if emu:
        rec["notes"] = "; ".join(filter(None, [rec["notes"], emu]))
    if kind == "special-register":
        names = sorted({m for a in anchors for m in re.findall(r"SR_\w+(?:\.[XYZ])?|c\[0x0\]\[0x[0-9a-f]+\]",
                                                              a.operands)})
        label = ".sreg" if row["id"] == "space.sreg" else "%" + row["id"].split(".", 1)[1]
        rec["modifiers_encoding"] = f"{label} -> {', '.join(names) if names else '?'}"
    elif kind != "application":
        rec["modifiers_encoding"] = modifier_encoding(mine, anchors, region_ops)
    return finish(rec, flags)


def region_opcodes(funcs: list[list[Insn]], anchors: list[Insn]) -> list[str]:
    out = []
    for fn in funcs:
        idx = [k for k, i in enumerate(fn) if i in anchors]
        if idx:
            out += [i.opcode for i in fn[max(0, min(idx) - WINDOW): max(idx) + WINDOW + 1]]
    return out


def finish(rec: dict, flags: list[str]) -> dict:
    rec["status"] = "flagged" if flags else "auto"
    if flags:
        rec["notes"] = "; ".join(filter(None, [rec["notes"], "needs review: " + ", ".join(flags)]))
    return rec


def apply_review(rec: dict, review: dict) -> dict:
    r = review.get(rec["feature_id"])
    if not r:
        return rec
    for k in ("sass_sequence", "sass_len", "sass_per_ptx", "modifiers_encoding", "hidden_mechanism"):
        if k in r:
            rec[k] = r[k]
    rec["notes"] = str(r.get("note", "")).strip()
    rec["status"] = "reviewed"
    return rec


# ---------------------------------------------------------------- outputs

def build_records(rows: list[dict], build: Path = S.BUILD) -> list[dict]:
    classes, review = load_classes(), load_review()
    out = []
    for row in sorted(rows, key=lambda r: r["id"]):
        if row["status"] != "in-scope":
            continue
        if row.get("entry") == "pending":
            rec = {c: "" for c in COLUMNS}
            rec.update(feature_id=row["id"], family=row["family"], tier=row["tier"], kind=row["kind"],
                       status="pending", notes="no corpus entry yet (pending in the catalog)")
            out.append(rec)
            continue
        out.append(apply_review(annotate_row(row, classes, build), review))
    return out


def write_csv(rows: list[dict], path: Path = S.CSV, build: Path = S.BUILD) -> int:
    recs = build_records(rows, build)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, lineterminator="\n")
        w.writeheader()
        w.writerows(recs)
    flagged = [r for r in recs if r["status"] == "flagged"]
    review_tsv = build / "review.tsv"
    review_tsv.parent.mkdir(parents=True, exist_ok=True)
    review_tsv.write_text("".join(f"{r['feature_id']}\t{r['entry']}\t{r['notes']}\t{r['sass_sequence']}\n"
                                  for r in flagged))
    counts = {s: sum(1 for r in recs if r["status"] == s) for s in STATUSES}
    print(f"{path.relative_to(common.ROOT)}: {len(recs)} rows; " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    if flagged:
        print(f"{len(flagged)} rows need review, listed in {review_tsv.relative_to(common.ROOT)}")
    return 0


def check(rows: list[dict], path: Path = S.CSV) -> int:
    """Without any tool: every in-scope row has a CSV row, every entry has ptxas and SASS files, no stale
    files, no row left flagged, and every mechanism and status is a known value."""
    errors = []
    if not path.exists():
        print(f"missing {path.relative_to(common.ROOT)}")
        return 1
    recs = {r["feature_id"]: r for r in csv.DictReader(path.open())}
    entries = {Path(r["entry"]).name for r in rows if r["status"] == "in-scope" and r.get("entry") not in
               (None, "", "pending")}
    for r in rows:
        if r["status"] != "in-scope":
            if r["id"] in recs:
                errors.append(f"{r['id']}: excluded row in the CSV")
            continue
        rec = recs.get(r["id"])
        if rec is None:
            errors.append(f"{r['id']}: no CSV row")
            continue
        if rec["status"] not in STATUSES:
            errors.append(f"{r['id']}: unknown status {rec['status']!r}")
        if rec["status"] == "flagged":
            errors.append(f"{r['id']}: flagged and not reviewed")
        for m in filter(None, rec["hidden_mechanism"].split(";")):
            if m not in MECHANISMS:
                errors.append(f"{r['id']}: unknown hidden_mechanism {m!r}")
    for eid in sorted(entries):
        for p in (S.PTXAS_DIR / f"{eid}.txt", S.SASS_DIR / f"{eid}.sass"):
            if not p.exists():
                errors.append(f"missing {p.relative_to(common.ROOT)}")
    for d, ext in ((S.PTXAS_DIR, ".txt"), (S.SASS_DIR, ".sass")):
        for p in sorted(d.glob(f"*{ext}")):
            if p.stem not in entries:
                errors.append(f"stale {p.relative_to(common.ROOT)}")
    unknown = set(recs) - {r["id"] for r in rows}
    errors += [f"{u}: CSV row for an unknown feature" for u in sorted(unknown)]
    for e in errors:
        print(e)
    print(f"sass evidence: {len(recs)} CSV rows, {len(entries)} entries, {len(errors)} problems")
    return 1 if errors else 0

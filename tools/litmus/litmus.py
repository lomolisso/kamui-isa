"""Parse and print litmus tests in the PTX dialect of Dartagnan (Dat3M).

A test looks like this (Dat3M's `litmus/PTX/Manual/MP-cta-gpu.litmus`):

    PTX MP-cta-gpu
    "Message passing, sync because release/acquire operations are morally strong"
    {
    x=0;
    y=0;
    P1:r1=0;
    P1:r2=0;
    }
     P0@cta 0,gpu 0         | P1@cta 0,gpu 0         ;
     st.weak x, 1           | ld.acquire.gpu r1, y   ;
     st.release.cta y, 1    | ld.weak r2, x          ;
    exists
    (P1:r1 == 1 /\\ P1:r2 != 1)

Parts: the architecture and the test name; optional quoted comments (which may span lines); the initial state in
braces; one column per thread, separated by `|`, each row ending in `;`, where the first row places each thread
in a CTA and a GPU; and the final condition with its quantifier (`exists`, `~exists` or `forall`).

Instructions use Dat3M's short forms: `st.weak x, 1`, `ld.acquire.gpu r1, y`, `atom.acq_rel.gpu.add r0, x, 1`,
`fence.sc.cta`, `fence.proxy.alias`, `bar.cta.sync 1`, branches `beq r1, 1, LC00` and labels `LC00:`.

One extension of ours, which Dartagnan does not parse: a thread may name its cluster, `P0@cta 0,cluster 0,gpu 0`,
and an instruction may use the `.cluster` scope. Tests that use either are run through the Alloy model only.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

QUANTIFIERS = ("exists", "~exists", "forall")
SCOPES = ("cta", "cluster", "gpu", "sys")
ORDERINGS = ("weak", "relaxed", "acquire", "release", "acq_rel", "sc", "volatile")
PROXY_OPS = ("tld", "suld", "sust", "cold", "suatom", "sured")
# Mnemonics Dartagnan's PTX front end knows (LitmusPTX.g4 in Dat3M 4.4.1).
DAT3M_OPS = {"ld", "st", "atom", "red", "fence", "bar", "label", "add", "sub", "mul", "div", "goto",
             "beq", "bne", "blt", "bgt", "ble", "bge", *PROXY_OPS}


class LitmusError(ValueError):
    pass


# ----------------------------------------------------------------------------------------------- instructions


@dataclass
class Instr:
    """One instruction cell. `op` is the mnemonic without qualifiers (`st`, `ld`, `atom`, `fence`, `bar`, ...)."""

    text: str
    op: str = ""
    quals: list[str] = field(default_factory=list)
    args: list[str] = field(default_factory=list)
    label: str | None = None

    @property
    def scope(self) -> str | None:
        return next((q for q in self.quals if q in SCOPES), None)

    @property
    def order(self) -> str | None:
        return next((q for q in self.quals if q in ORDERINGS), None)

    @property
    def is_empty(self) -> bool:
        return not self.text


def parse_instr(text: str) -> Instr:
    text = " ".join(text.split())
    if not text:
        return Instr(text="")
    m = re.fullmatch(r"(LC\d+):", text)
    if m:
        return Instr(text=text, op="label", label=m.group(1))
    head, _, rest = text.partition(" ")
    parts = head.split(".")
    args = [a.strip() for a in rest.split(",")] if rest.strip() else []
    if any(a == "" for a in args):
        raise LitmusError(f"empty operand in {text!r}")
    return Instr(text=text, op=parts[0], quals=parts[1:], args=args)


# ----------------------------------------------------------------------------------------------- conditions


@dataclass(frozen=True)
class Cmp:
    lhs: str
    op: str
    rhs: str

    def __str__(self) -> str:
        return f"{self.lhs} {self.op} {self.rhs}"


@dataclass(frozen=True)
class Not:
    arg: object

    def __str__(self) -> str:
        return f"~({self.arg})"


@dataclass(frozen=True)
class And:
    args: tuple

    def __str__(self) -> str:
        return " /\\ ".join(_paren(a, Or) for a in self.args)


@dataclass(frozen=True)
class Or:
    args: tuple

    def __str__(self) -> str:
        return " \\/ ".join(str(a) for a in self.args)


def _paren(e, kind) -> str:
    return f"({e})" if isinstance(e, kind) else str(e)


_TOKEN = re.compile(
    r"\s*(?:(?P<op>/\\|\\/|==|!=|<=|>=|=|<|>|~|\(|\))|(?P<val>-?0x[0-9a-fA-F]+|P?\d+\s*:\s*\w+|-?\d+|\w+(?:\[\d+\])?))"
)


def _tokens(text: str) -> list[str]:
    out, pos, text = [], 0, text.strip()
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m or m.end() == pos:
            raise LitmusError(f"cannot read condition at {text[pos:pos + 20]!r}")
        out.append(m.group("op") or re.sub(r"\s+", "", m.group("val")))
        pos = m.end()
        while pos < len(text) and text[pos].isspace():
            pos += 1
    return out


def parse_condition(text: str):
    toks = _tokens(text)
    if toks and toks[0] == "not":
        toks[0] = "~"
    pos = 0

    def peek():
        return toks[pos] if pos < len(toks) else None

    def take(expected=None):
        nonlocal pos
        t = peek()
        if t is None or (expected is not None and t != expected):
            raise LitmusError(f"condition: expected {expected!r}, got {t!r} in {text!r}")
        pos += 1
        return t

    def p_or():
        args = [p_and()]
        while peek() == "\\/":
            take()
            args.append(p_and())
        return args[0] if len(args) == 1 else Or(tuple(args))

    def p_and():
        args = [p_not()]
        while peek() == "/\\":
            take()
            args.append(p_not())
        return args[0] if len(args) == 1 else And(tuple(args))

    def p_not():
        if peek() in ("~", "not"):
            take()
            return Not(p_not())
        if peek() == "(":
            take("(")
            e = p_or()
            take(")")
            return e
        lhs = take()
        op = take()
        if op not in ("==", "=", "!=", "<=", ">=", "<", ">"):
            raise LitmusError(f"condition: bad comparison {op!r} in {text!r}")
        return Cmp(lhs, "==" if op == "=" else op, take())

    e = p_or()
    if pos != len(toks):
        raise LitmusError(f"condition: trailing text {toks[pos:]} in {text!r}")
    return e


def cond_atoms(e) -> list[Cmp]:
    if isinstance(e, Cmp):
        return [e]
    if isinstance(e, Not):
        return cond_atoms(e.arg)
    return [a for x in e.args for a in cond_atoms(x)]


# ----------------------------------------------------------------------------------------------- tests


@dataclass
class Thread:
    tid: int
    cta: int
    gpu: int
    cluster: int | None = None
    instrs: list[Instr] = field(default_factory=list)

    @property
    def placement(self) -> str:
        c = f",cluster {self.cluster}" if self.cluster is not None else ""
        return f"P{self.tid}@cta {self.cta}{c},gpu {self.gpu}"


@dataclass
class Litmus:
    arch: str
    name: str
    comments: str  # the raw text between the name line and the initial state, quotes included
    init: list[str]  # declarators, without the trailing ';'
    threads: list[Thread]
    quantifier: str
    cond_text: str
    condition: object
    text: str = ""
    cond_offset: int = 0  # index in `text` where the quantifier starts

    def instrs(self):
        for t in self.threads:
            for i in t.instrs:
                if not i.is_empty:
                    yield t, i

    @property
    def uses_cluster(self) -> bool:
        return any(t.cluster is not None for t in self.threads) or any(i.scope == "cluster" for _, i in self.instrs())

    @property
    def uses_cluster_scope(self) -> bool:
        """True if an instruction uses the `.cluster` scope (placement alone does not count)."""
        return any(i.scope == "cluster" for _, i in self.instrs())

    @property
    def uses_ptx86_fences(self) -> bool:
        """`fence.acquire` and `fence.release` (PTX ISA 8.6), which no published formal model covers."""
        return any(i.op == "fence" and i.order in ("acquire", "release") for _, i in self.instrs())

    @property
    def dartagnan_ok(self) -> bool:
        """Can Dartagnan's PTX models (v6.0, v7.5) answer this test? Not with `.cluster`, PTX 8.6 fences or
        instructions its parser does not know. Cluster placement alone is fine: it is erased before the run."""
        if self.uses_cluster_scope or self.uses_ptx86_fences:
            return False
        return all(i.op in DAT3M_OPS and i.order != "volatile" and not any("::" in q for q in i.quals)
                   for _, i in self.instrs())

    def without_clusters(self) -> str:
        """The test text with cluster placement removed (for Dartagnan, which does not parse it)."""
        return re.sub(r",\s*cluster\s+\d+\s*,", ",", self.text)

    @property
    def uses_proxy(self) -> bool:
        """True if the test needs the mixed-proxy (PTX 7.5) model: proxy fences, aliases, non-generic accesses."""
        if any("aliases" in d for d in self.init):
            return True
        return any(i.op in PROXY_OPS or (i.op == "fence" and "proxy" in i.quals) for _, i in self.instrs())

    @property
    def has_loops(self) -> bool:
        return any(i.op == "label" for _, i in self.instrs())

    @property
    def has_barrier(self) -> bool:
        return any(i.op == "bar" for _, i in self.instrs())

    @property
    def locations(self) -> list[str]:
        locs = []
        for d in self.init:
            lhs = d.split("=")[0].split("@")[0].strip()
            if ":" not in lhs and lhs not in locs:
                locs.append(lhs)
        return locs

    def format(self) -> str:
        """Print the test in the dialect, with aligned columns."""
        cols = [[t.placement] + [i.text for i in t.instrs] for t in self.threads]
        nrows = max(len(c) for c in cols)
        for c in cols:
            c.extend([""] * (nrows - len(c)))
        widths = [max(len(x) for x in c) for c in cols]
        lines = [f"{self.arch} {self.name}"]
        if self.comments.strip():
            lines.append(self.comments.strip())
        lines.append("{")
        lines += [f"{d};" for d in self.init]
        lines.append("}")
        for r in range(nrows):
            lines.append(" " + " | ".join(cols[k][r].ljust(widths[k]) for k in range(len(cols))) + " ;")
        lines.append(self.quantifier)
        lines.append(f"({self.cond_text})" if not self.cond_text.startswith("(") else self.cond_text)
        return "\n".join(lines) + "\n"


_PLACE = re.compile(r"P(\d+)\s*@\s*cta\s+(\d+)\s*,\s*(?:cluster\s+(\d+)\s*,\s*)?gpu\s+(\d+)")


def parse(text: str, path: str | Path | None = None) -> Litmus:
    where = f"{path}: " if path else ""
    try:
        return _parse(text)
    except LitmusError as e:
        raise LitmusError(f"{where}{e}") from None


def _parse(text: str) -> Litmus:
    m = re.match(r"\s*(\S+)[ \t]+(\S+)[ \t]*\n", text)
    if not m:
        raise LitmusError("first line must be '<arch> <name>'")
    arch, name = m.group(1), m.group(2)
    if arch.upper() != "PTX":
        raise LitmusError(f"not a PTX test: {arch}")
    brace = _find_brace(text, m.end())
    comments = text[m.end():brace]
    close = text.index("}", brace)
    init = [d.strip() for d in text[brace + 1:close].split(";") if d.strip()]
    qm = re.compile(r"^\s*(~\s*exists|exists|forall)\b", re.M).search(text, close + 1)
    if not qm:
        raise LitmusError("no final condition (exists, ~exists, forall)")
    body = text[close + 1:qm.start()]
    quant = re.sub(r"\s+", "", qm.group(1))
    cond_text = " ".join(text[qm.end():].split())
    rows = [r for r in (ln.strip() for ln in body.splitlines()) if r]
    if not rows:
        raise LitmusError("no threads")
    threads = []
    for cell in _cells(rows[0]):
        pm = _PLACE.fullmatch(cell.strip())
        if not pm:
            raise LitmusError(f"bad thread placement {cell!r}")
        tid, cta, cl, gpu = pm.groups()
        threads.append(Thread(int(tid), int(cta), int(gpu), int(cl) if cl is not None else None))
    for r in rows[1:]:
        cells = _cells(r)
        if len(cells) != len(threads):
            raise LitmusError(f"row has {len(cells)} columns, expected {len(threads)}: {r!r}")
        for t, c in zip(threads, cells):
            t.instrs.append(parse_instr(c))
    for t in threads:
        while t.instrs and t.instrs[-1].is_empty:
            t.instrs.pop()
    return Litmus(arch, name, comments, init, threads, quant, cond_text, parse_condition(cond_text), text, qm.start())


def _find_brace(text: str, start: int) -> int:
    """Index of the '{' that opens the initial state, skipping quoted comments."""
    i, quoted = start, False
    while i < len(text):
        ch = text[i]
        if ch == '"':
            quoted = not quoted
        elif ch == "{" and not quoted:
            return i
        i += 1
    raise LitmusError("no initial state '{ ... }'")


def _cells(row: str) -> list[str]:
    if not row.endswith(";"):
        raise LitmusError(f"row does not end with ';': {row!r}")
    return row[:-1].split("|")


def load(path: str | Path) -> Litmus:
    return parse(Path(path).read_text(encoding="utf-8"), path)


# ----------------------------------------------------------------------------------------------- normalization


def normalize(text: str, path: str | Path | None = None) -> tuple[str, str]:
    """Rewrite the final condition as an `exists` condition. Returns (new text, original quantifier).

    - `exists C` stays as it is: the question is "can C happen?".
    - `~exists C` becomes `exists C`: the original test claimed C is impossible, so its expected result is
      `forbidden`.
    - `forall C` becomes `exists ~(C)`: the original claimed C always holds, so "can C fail?" is expected
      `forbidden`.
    The rest of the text is kept byte for byte.
    """
    t = parse(text, path)
    head = text[:t.cond_offset]
    if t.quantifier == "exists":
        new = f"exists\n({t.cond_text})" if not t.cond_text.startswith("(") else f"exists\n{t.cond_text}"
    elif t.quantifier == "~exists":
        new = f"exists\n{t.cond_text}" if t.cond_text.startswith("(") else f"exists\n({t.cond_text})"
    else:
        new = f"exists\n~({t.cond_text})"
    out = head + new + "\n"
    parse(out, path)  # must still parse
    return out, t.quantifier


def expected_from_quantifier(quantifier: str, holds: bool) -> str:
    """Translate an upstream PASS/FAIL verdict (`holds`) on the original quantifier to allowed/forbidden of the
    normalized `exists` condition."""
    if quantifier == "exists":
        return "allowed" if holds else "forbidden"
    return "forbidden" if holds else "allowed"

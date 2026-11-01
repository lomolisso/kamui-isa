#!/usr/bin/env python3
"""Lower PTX litmus tests to RISC-V with a naive mapping, for herd7 and the RVWMO model.

    python tools/litmus/to_riscv.py            # write tests/litmus/riscv/<test>.litmus for every test it can lower
    python tools/litmus/to_riscv.py --check    # fail if a committed file is missing, stale or orphaned
    python tools/litmus/to_riscv.py --why      # list the tests it cannot lower, with the reason

The question this answers: if every PTX memory instruction were lowered to plain RISC-V, with every scope erased
(treated as system scope) and the orderings mapped the way the RISC-V specification maps C++ atomics (unprivileged
spec, appendix "RVWMO Explanatory Material", table "Mappings from C/C++ primitives to RISC-V primitives"), would
every outcome that PTX forbids still be forbidden? RVWMO is stronger than PTX (multi-copy atomic, total
coherence), so the answer should be yes; a "no" would mean a fence is missing from the mapping. The outcomes PTX
allows but this lowering forbids show what plain RVWMO hardware already guarantees and what a weaker, scoped
Kamui implementation would give up.

| PTX | RISC-V |
|---|---|
| `ld.weak`, `ld.relaxed.<s>`, `ld.volatile` | `lw` |
| `ld.acquire.<s>` | `lw; fence r,rw` |
| `st.weak`, `st.relaxed.<s>`, `st.volatile` | `sw` |
| `st.release.<s>` | `fence rw,w; sw` |
| `fence.sc.<s>` | `fence rw,rw` |
| `fence.acq_rel.<s>` | `fence.tso` |
| `fence.acquire.<s>` / `fence.release.<s>` | `fence r,rw` / `fence rw,w` |
| `atom.<sem>.<s>.add`, `.exch`, `.and`, `.or`, `.xor` | `amoadd.w`, `amoswap.w`, `amoand.w`, `amoor.w`, `amoxor.w` with `.aq` (acquire), `.rl` (release), `.aqrl` (acq_rel) |
| `red...` | the same AMO with `x0` as destination |

Registers: thread-local PTX register `rK` is `x(10+K)`; location addresses are in `x5`, `x6`, `x28`..`x31`; `x7`
holds store constants. Not lowered: proxies, barriers, loops, compare-and-swap, register arithmetic, and
instructions with a state space.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import litmus  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "tests" / "litmus"
OUT = SUITE / "riscv"
ADDR_REGS = ["x5", "x6", "x28", "x29", "x30", "x31"]
AMO = {"add": "amoadd", "exch": "amoswap", "and": "amoand", "or": "amoor", "xor": "amoxor"}
AQRL = {"relaxed": "", "acquire": ".aq", "release": ".rl", "acq_rel": ".aqrl", "sc": ".aqrl"}


class Unsupported(Exception):
    pass


def _const(v: str) -> int | None:
    try:
        return int(v, 0)
    except ValueError:
        return None


def reg(r: str) -> str:
    m = re.fullmatch(r"r(\d+)", r)
    if not m or int(m.group(1)) > 15:
        raise Unsupported(f"register {r}")
    return f"x{10 + int(m.group(1))}"


def lower_thread(th: litmus.Thread, addr: dict[str, str]) -> list[str]:
    out = []

    def value(v: str) -> str:
        c = _const(v)
        if c is None:
            return reg(v)
        if not -2048 <= c < 2048:
            raise Unsupported(f"constant {c}")
        out.append(f"ori x7,x0,{c}")
        return "x7"

    for ins in th.instrs:
        if ins.is_empty:
            continue
        if any("::" in q for q in ins.quals):
            raise Unsupported(f"state space in {ins.text!r}")
        o = ins.order
        if ins.op == "ld" and not ins.quals:
            c = _const(ins.args[1])
            if c is None:
                raise Unsupported(f"instruction {ins.text!r}")
            out.append(f"ori {reg(ins.args[0])},x0,{c}")
        elif ins.op == "ld" and o in ("weak", "relaxed", "volatile", "acquire"):
            out.append(f"lw {reg(ins.args[0])},0({addr[ins.args[1]]})")
            if o == "acquire":
                out.append("fence r,rw")
        elif ins.op == "st" and o in ("weak", "relaxed", "volatile", "release"):
            v = value(ins.args[1])
            if o == "release":
                out.insert(len(out) - (1 if v == "x7" else 0), "fence rw,w")
            out.append(f"sw {v},0({addr[ins.args[0]]})")
        elif ins.op == "fence" and o in ("sc", "acq_rel", "acquire", "release") and "proxy" not in ins.quals:
            out.append({"sc": "fence rw,rw", "acq_rel": "fence.tso", "acquire": "fence r,rw",
                        "release": "fence rw,w"}[o])
        elif ins.op in ("atom", "red") and o in AQRL:
            opname = next((q for q in ins.quals if q in AMO), None)
            if opname is None:
                raise Unsupported(f"instruction {ins.text!r}")
            if ins.op == "atom":
                rd, loc, v = ins.args
                rd = reg(rd)
            else:
                (loc, v), rd = ins.args, "x0"
            out.append(f"{AMO[opname]}.w{AQRL[o]} {rd},{value(v)},({addr[loc]})")
        else:
            raise Unsupported(f"instruction {ins.text!r}")
    return out


def cond_text(e) -> str:
    if isinstance(e, litmus.Cmp):
        if e.op not in ("==", "!="):
            raise Unsupported(f"condition {e}")
        lhs = e.lhs
        m = re.fullmatch(r"P?(\d+):(r\d+)", lhs)
        if m:
            lhs = f"{m.group(1)}:{reg(m.group(2))}"
        s = f"{lhs}={e.rhs}"
        return s if e.op == "==" else f"~({s})"
    if isinstance(e, litmus.Not):
        return f"~({cond_text(e.arg)})"
    op = " /\\ " if isinstance(e, litmus.And) else " \\/ "
    return "(" + op.join(cond_text(a) for a in e.args) + ")"


def translate(t: litmus.Litmus) -> str:
    if t.uses_proxy:
        raise Unsupported("proxies")
    if t.has_loops:
        raise Unsupported("loops")
    if t.has_barrier:
        raise Unsupported("barriers")
    init, cols = [], []
    for th in t.threads:
        used = list(dict.fromkeys(a for i in th.instrs for a in i.args
                                  if re.fullmatch(r"[A-Za-z_]\w*", a) and not re.fullmatch(r"r\d+|LC\d+", a)))
        if len(used) > len(ADDR_REGS):
            raise Unsupported("too many locations")
        addr = dict(zip(used, ADDR_REGS))
        init += [f"{th.tid}:{r}={loc};" for loc, r in addr.items()]
        cols.append(lower_thread(th, addr))
    for d in t.init:
        lhs, _, rhs = (s.strip() for s in d.partition("="))
        if ":" not in lhs and "@" not in lhs and _const(rhs) not in (0, None):
            init.append(f"{lhs}={rhs};")
        elif ":" in lhs and _const(rhs) not in (0, None):
            raise Unsupported(f"initial register value {d}")
    rows = max(len(c) for c in cols)
    width = [max([len(f"P{th.tid}")] + [len(x) for x in c]) for th, c in zip(t.threads, cols)]
    lines = [f"RISCV {t.name}", f'"Naive RVWMO lowering (scopes erased) of tests/litmus/{{}}.litmus"', "{"]
    lines.append(" ".join(init))
    lines.append("}")
    lines.append(" " + " | ".join(f"P{th.tid}".ljust(w) for th, w in zip(t.threads, width)) + " ;")
    for k in range(rows):
        lines.append(" " + " | ".join((c[k] if k < len(c) else "").ljust(w) for c, w in zip(cols, width)) + " ;")
    lines.append(f"exists {cond_text(t.condition)}")
    return "\n".join(lines) + "\n"


def tests() -> list[Path]:
    return sorted((SUITE / "ptx").rglob("*.litmus"))


def test_id(p: Path) -> str:
    return p.relative_to(SUITE).with_suffix("").as_posix()


def riscv_path(tid: str) -> Path:
    return OUT / (tid.removeprefix("ptx/") + ".litmus")


def generate() -> tuple[dict[Path, str], dict[str, str]]:
    files, skipped = {}, {}
    for p in tests():
        tid = test_id(p)
        try:
            files[riscv_path(tid)] = translate(litmus.load(p)).replace("{}", tid, 1)
        except Unsupported as e:
            skipped[tid] = str(e)
    return files, skipped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--why", action="store_true")
    a = ap.parse_args()
    files, skipped = generate()
    if a.why:
        for tid, why in sorted(skipped.items()):
            print(f"{tid}: {why}")
    if a.check:
        bad = [p for p, s in files.items() if not p.exists() or p.read_text() != s]
        extra = sorted(set(OUT.rglob("*.litmus")) - set(files)) if OUT.exists() else []
        for p in bad + extra:
            print(f"differs or orphaned: {p.relative_to(ROOT)}")
        print(f"{len(files)} tests, {len(bad)} differ, {len(extra)} orphaned")
        return 1 if bad or extra else 0
    for p in set(OUT.rglob("*.litmus")) - set(files) if OUT.exists() else []:
        p.unlink()
    for p, s in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(s)
    print(f"wrote {len(files)} RISC-V tests, skipped {len(skipped)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

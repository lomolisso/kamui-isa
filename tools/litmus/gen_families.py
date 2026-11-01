#!/usr/bin/env python3
"""Generate the litmus test families in tests/litmus/ptx/kamui/families/.

    python tools/litmus/gen_families.py            # write the tests
    python tools/litmus/gen_families.py --check    # fail if a committed test differs or is missing

Each family is one classic shape (MP, SB, LB, IRIW, CoRR, WRC, ISA2, 2+2W) in several orderings, at each of the
four PTX scopes, with the threads placed three ways. A test is named `<shape>+<ordering>[.<scope>]+<placement>`,
for example `MP+rel-acq.gpu+same-cluster`.

Orderings (which ones a shape gets depends on what is meaningful for it):
- `weak`: plain `ld.weak`/`st.weak`, no fences (no scope);
- `relaxed`: every access `.relaxed.<scope>`;
- `rel-acq`: the signalling store is `.release`, the signalling load `.acquire`, data accesses weak (relaxed in
  WRC and IRIW, where the data accesses race);
- `fence-acq_rel`, `fence-sc`: relaxed accesses with `fence.acq_rel` or `fence.sc` between them;
- `fence-rel-acq` (MP only): `fence.release` before the flag store, `fence.acquire` after the flag load (PTX 8.6).

Placements: `same-cta` (all threads in CTA 0), `same-cluster` (thread i in CTA i, all in cluster 0),
`diff-cluster` (thread i in CTA i of cluster i). Every test records its cluster even when no instruction uses the
`.cluster` scope, because the H100 runs place threads by it; for Dartagnan the cluster is erased.

These tests have no upstream verdict: tools/litmus/run_formal.py gives them Dartagnan verdicts (no `.cluster`
scope, no PTX 8.6 fence) and 2019 Alloy model verdicts (all of them; `ptx-2019-alloy+ext` for the extensions).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import litmus  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tests" / "litmus" / "ptx" / "kamui" / "families"
SCOPES = ["cta", "cluster", "gpu", "sys"]
PLACEMENTS = ["same-cta", "same-cluster", "diff-cluster"]


def ld(o, s, r, loc):
    return f"ld.{o}.{s} {r}, {loc}" if o != "weak" else f"ld.weak {r}, {loc}"


def st(o, s, loc, v):
    return f"st.{o}.{s} {loc}, {v}" if o != "weak" else f"st.weak {loc}, {v}"


def fence(kind, s):
    return f"fence.{kind}.{s}"


def accesses(variant):
    """(signal store ordering, signal load ordering, data ordering, fence kind or None)."""
    return {
        "weak": ("weak", "weak", "weak", None),
        "relaxed": ("relaxed", "relaxed", "relaxed", None),
        "rel-acq": ("release", "acquire", "weak", None),
        "fence-acq_rel": ("relaxed", "relaxed", "weak", "acq_rel"),
        "fence-sc": ("relaxed", "relaxed", "weak", "sc"),
        "fence-rel-acq": ("relaxed", "relaxed", "weak", ("release", "acquire")),
    }[variant]


def fences(f, s):
    if f is None:
        return None, None
    if isinstance(f, tuple):
        return fence(f[0], s), fence(f[1], s)
    return fence(f, s), fence(f, s)


def mp(v, s):
    sw, sr, d, f = accesses(v)
    fw, fr = fences(f, s)
    t0 = [st(d, s, "x", 1)] + ([fw] if fw else []) + [st(sw, s, "y", 1)]
    t1 = [ld(sr, s, "r0", "y")] + ([fr] if fr else []) + [ld(d, s, "r1", "x")]
    return [t0, t1], "P1:r0 == 1 /\\ P1:r1 == 0", "Message passing: thread 1 sees the flag but stale data"


def sb(v, s):
    _, _, _, f = accesses(v)
    o = "weak" if v == "weak" else "relaxed"
    fw, _ = fences(f, s)
    mid = [fw] if fw else []
    t0 = [st(o, s, "x", 1)] + mid + [ld(o, s, "r0", "y")]
    t1 = [st(o, s, "y", 1)] + mid + [ld(o, s, "r1", "x")]
    return [t0, t1], "P0:r0 == 0 /\\ P1:r1 == 0", "Store buffering: both threads miss the other's store"


def lb(v, s):
    sw, sr, _, f = accesses(v)
    if v in ("weak", "relaxed"):
        sw = sr = v
    fw, _ = fences(f, s)
    mid = [fw] if fw else []
    t0 = [ld(sr, s, "r0", "x")] + mid + [st(sw, s, "y", 1)]
    t1 = [ld(sr, s, "r1", "y")] + mid + [st(sw, s, "x", 1)]
    return [t0, t1], "P0:r0 == 1 /\\ P1:r1 == 1", "Load buffering: each load sees the other thread's later store"


def iriw(v, s):
    sw, sr, _, f = accesses(v)
    if v in ("weak", "relaxed"):
        sw = sr = v
    _, fr = fences(f, s)
    mid = [fr] if fr else []
    w0, w1 = [st(sw, s, "x", 1)], [st(sw, s, "y", 1)]
    r2 = [ld(sr, s, "r0", "x")] + mid + [ld(sr, s, "r1", "y")]
    r3 = [ld(sr, s, "r2", "y")] + mid + [ld(sr, s, "r3", "x")]
    cond = "P2:r0 == 1 /\\ P2:r1 == 0 /\\ P3:r2 == 1 /\\ P3:r3 == 0"
    return [w0, w1, r2, r3], cond, "IRIW: two readers see two independent writes in opposite orders"


def corr(v, s):
    o = v
    return ([[st(o, s, "x", 1)], [ld(o, s, "r0", "x"), ld(o, s, "r1", "x")]], "P1:r0 == 1 /\\ P1:r1 == 0",
            "CoRR: a thread reads a new value, then an older one, of the same location")


def wrc(v, s):
    sw, sr, _, f = accesses(v)
    d = "weak" if v == "weak" else "relaxed"
    fw, fr = fences(f, s)
    t0 = [st(d, s, "x", 1)]
    t1 = [ld(d, s, "r0", "x")] + ([fw] if fw else []) + [st(sw if v != "weak" else "weak", s, "y", 1)]
    t2 = [ld(sr if v != "weak" else "weak", s, "r1", "y")] + ([fr] if fr else []) + [ld(d, s, "r2", "x")]
    return [t0, t1, t2], "P1:r0 == 1 /\\ P2:r1 == 1 /\\ P2:r2 == 0", \
        "WRC: write-to-read causality, a three-thread chain through two locations"


def isa2(v, s):
    sw, sr, d, _ = accesses(v)
    t0 = [st(d, s, "x", 1), st(sw, s, "y", 1)]
    t1 = [ld(sr, s, "r0", "y"), st(sw, s, "z", 1)]
    t2 = [ld(sr, s, "r1", "z"), ld(d, s, "r2", "x")]
    return [t0, t1, t2], "P1:r0 == 1 /\\ P2:r1 == 1 /\\ P2:r2 == 0", \
        "ISA2: message passing through a third thread (transitivity of synchronization)"


def two_plus_two_w(v, s):
    _, _, _, f = accesses(v)
    o = "weak" if v == "weak" else "relaxed"
    fw, _ = fences(f, s)
    mid = [fw] if fw else []
    t0 = [st(o, s, "x", 1)] + mid + [st(o, s, "y", 2)]
    t1 = [st(o, s, "y", 1)] + mid + [st(o, s, "x", 2)]
    return [t0, t1], "x == 1 /\\ y == 1", "2+2W: both first stores end up last in coherence order"


FAMILIES = {
    "MP": (mp, ["weak", "relaxed", "rel-acq", "fence-acq_rel", "fence-sc", "fence-rel-acq"]),
    "SB": (sb, ["weak", "relaxed", "fence-acq_rel", "fence-sc"]),
    "LB": (lb, ["weak", "relaxed", "rel-acq", "fence-acq_rel"]),
    "IRIW": (iriw, ["weak", "relaxed", "rel-acq", "fence-acq_rel", "fence-sc"]),
    "CoRR": (corr, ["weak", "relaxed"]),
    "WRC": (wrc, ["weak", "rel-acq", "fence-acq_rel", "fence-sc"]),
    "ISA2": (isa2, ["weak", "rel-acq"]),
    "2+2W": (two_plus_two_w, ["weak", "relaxed", "fence-sc"]),
}


def placement(n: int, kind: str) -> list[tuple[int, int]]:
    """(cta, cluster) for each of n threads."""
    if kind == "same-cta":
        return [(0, 0)] * n
    if kind == "same-cluster":
        return [(i, 0) for i in range(n)]
    return [(i, i) for i in range(n)]


def make(shape: str, variant: str, scope: str, place: str) -> tuple[str, str]:
    fn, _ = FAMILIES[shape]
    threads, cond, what = fn(variant, scope)
    name = f"{shape}+{variant}" + (f".{scope}" if variant != "weak" else "") + f"+{place}"
    locs = sorted({i.split()[1].rstrip(",") if i.startswith("st") else i.split()[-1]
                   for t in threads for i in t if not i.startswith("fence")})
    regs = [f"P{k}:{i.split()[1].rstrip(',')}" for k, t in enumerate(threads) for i in t if i.startswith("ld")]
    t = litmus.Litmus(arch="PTX", name=name, comments=f'"{what}; {place.replace("-", " ")}"',
                      init=[f"{loc}=0" for loc in locs] + [f"{r}=0" for r in regs], threads=[],
                      quantifier="exists", cond_text=cond, condition=None)
    for k, (body, (cta, cl)) in enumerate(zip(threads, placement(len(threads), place))):
        t.threads.append(litmus.Thread(k, cta, 0, cl, [litmus.parse_instr(i) for i in body]))
    text = t.format()
    litmus.parse(text, name)
    return name, text


def generate() -> dict[Path, str]:
    files = {}
    for shape, (_, variants) in FAMILIES.items():
        for v in variants:
            for s in (["-"] if v == "weak" else SCOPES):
                for p in PLACEMENTS:
                    name, text = make(shape, v, s, p)
                    files[OUT / shape / f"{name}.litmus"] = text
    return files


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    files = generate()
    if a.check:
        bad = [p for p, s in files.items() if not p.exists() or p.read_text() != s]
        extra = sorted(set(OUT.rglob("*.litmus")) - set(files))
        for p in bad + extra:
            print(f"differs or orphaned: {p.relative_to(ROOT)}")
        print(f"{len(files)} tests, {len(bad)} differ, {len(extra)} orphaned")
        return 1 if bad or extra else 0
    for p in set(OUT.rglob("*.litmus")) - set(files):
        p.unlink()
    for p, s in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(s)
    print(f"wrote {len(files)} tests")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Decode the outputs of the probe kernels (tests/probes/, jobs/isa-probes.sh) into Markdown tables.

    python tools/evidence/probes.py evidence/probes/<job>            # print the tables
    python tools/evidence/probes.py evidence/probes/<job> --write    # also write <job>/results.md

A job folder holds goldens/<probe>/golden.yaml (buffer offsets) and runs/<probe>/run<k>.bin (every run). Each
probe's section says what was measured and how to read it; the kernels' header comments describe the probes.
"""
from __future__ import annotations

import argparse
import statistics
import struct
import sys
from pathlib import Path

import yaml

FAIL = 0xFFFFFFFF
LAT_OPS = [
    "ld_weak", "ld_volatile", "ld_relaxed_cta", "ld_relaxed_cluster", "ld_relaxed_gpu", "ld_relaxed_sys",
    "ld_acquire_cta", "ld_acquire_cluster", "ld_acquire_gpu", "ld_acquire_sys",
    "st_weak", "st_relaxed_cta", "st_relaxed_cluster", "st_relaxed_gpu", "st_relaxed_sys",
    "st_release_cta", "st_release_cluster", "st_release_gpu", "st_release_sys",
    "atom_relaxed_cta", "atom_relaxed_cluster", "atom_relaxed_gpu", "atom_relaxed_sys",
    "atom_acq_rel_cta", "atom_acq_rel_cluster", "atom_acq_rel_gpu", "atom_acq_rel_sys",
    "red_relaxed_gpu", "red_release_gpu",
    "fence_acq_rel_cta", "fence_acq_rel_cluster", "fence_acq_rel_gpu", "fence_acq_rel_sys",
    "fence_sc_cta", "fence_sc_cluster", "fence_sc_gpu", "fence_sc_sys",
    "fence_proxy_async", "fence_proxy_async_global", "fence_proxy_async_shared_cta", "fence_proxy_alias",
    "mbarrier_arrive", "mbarrier_arrive_try_wait",
]
WARP_OPS = ["redux_sync_add", "shfl_tree_add", "vote_ballot", "match_any", "activemask", "bar_warp_sync",
            "elect_sync", "read_ctaid"]
REPS = 32
ADDR_FIELDS = [
    "gen_static", "gen_dynamic", "sh_static", "sh_dynamic", "rank", "clusterid", "smid", "nctarank",
    "mapa_gen0", "mapa_gen1", "mapa_sh0", "mapa_sh1", "res_begin", "res_end", "res_cap", "total_smem",
    "dyn_smem", "aggr_smem", "p_sh", "p_shc", "p_global", "p_local", "p_remote_sh", "p_remote_shc",
    "sh_lo", "sh_hi", "shc_lo", "shc_hi", "local_lo", "local_hi", "gen_local", "local_off",
    "p_local_local", "gen_global", "p_global_global", "p_sh_past_dyn", "sh_to_remote_gen", "p_global_0x1000",
]
RECONV_POINTS = ["if side", "else side", "after if/else", "after loop (lane % 8 trips)", "after break loop",
                 "nested if", "after nested if", "after loop + __syncwarp", "after early return (lanes < 24)"]
FMT = {"u32": "I", "s32": "i", "u64": "Q"}


class Probe:
    def __init__(self, job: Path, name: str):
        self.name = name
        g = yaml.safe_load((job / "goldens" / name / "golden.yaml").read_text())
        self.result = g.get("result", "?")
        self.layout = {o["name"]: o for o in g.get("outputs", [])}
        self.runs = [p.read_bytes() for p in sorted((job / "runs" / name).glob("run*.bin"))]

    def buf(self, run: bytes, name: str) -> list[int]:
        o = self.layout[name]
        return list(struct.unpack_from(f"<{o['count']}{FMT[o['dtype']]}", run, o["offset"]))


def med(xs):
    return statistics.median(xs) if xs else float("nan")


def table(head: list[str], rows: list[list]) -> str:
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def its_lock(p: Probe) -> str:
    rows = []
    for k, r in enumerate(p.runs):
        tries, cyc, order = p.buf(r, "tries"), p.buf(r, "cycles"), p.buf(r, "order")
        done = [t for t in tries if t != FAIL]
        rows.append([k, f"{len(done)}/32", max(done) if done else "-", max(cyc),
                     " ".join(str(x) for x in order[:len(done)][:8]) + (" ..." if len(done) > 8 else "")])
    return table(["run", "lanes that got the lock", "max tries", "max cycles", "first lanes in order"], rows)


def its_cross(p: Probe) -> str:
    # ptxas reads the clock once before the branch (both sides show the same entry time), so only the waits count.
    rows = []
    for k, r in enumerate(p.runs):
        res = p.buf(r, "res")
        ev = [x for x in res[0::2] if x != FAIL]
        od = [x for x in res[1::2] if x != FAIL]
        rows.append([k, f"{len(ev)}/16", f"{len(od)}/16", max(ev) if ev else "-", max(od) if od else "-"])
    return table(["run", "if side (even lanes) finished", "else side (odd lanes) finished",
                  "max reads waited, even", "max reads waited, odd"], rows)


def its_pc(p: Probe) -> str:
    rows = []
    for k, r in enumerate(p.runs):
        got, waits = p.buf(r, "got"), p.buf(r, "waits")
        ok = sum(got[i] == i * 7 + 1 for i in range(1, 32))
        rows.append([k, f"{ok}/31", max(waits[1:])])
    return table(["run", "consumers that got their value", "max reads waited"], rows)


def reconv(p: Probe) -> str:
    r = p.runs[0]
    mask, t = p.buf(r, "mask"), p.buf(r, "t")
    rows = []
    for k, name in enumerate(RECONV_POINTS):
        ms = sorted({mask[k * 32 + i] for i in range(32) if mask[k * 32 + i]})
        ts = [t[k * 32 + i] for i in range(32) if mask[k * 32 + i]]
        rows.append([k, name, " ".join(f"{m:08x}" for m in ms), f"{min(ts)}..{max(ts)}" if ts else "-"])
    s = table(["point", "where", "distinct active masks (run 0)", "cycles"], rows)
    same = all(r2 == p.runs[0] for r2 in p.runs[1:])
    ifs = [t[0 * 32 + i] for i in range(1, 32, 2)]
    els = [t[1 * 32 + i] for i in range(0, 32, 2)]
    order = "if side first" if max(ifs) < min(els) else "else side first" if max(els) < min(ifs) else "interleaved"
    return s + f"\n\nThe two sides of the first branch ran: {order}. Masks identical in all runs: " \
               f"{all(p.buf(x, 'mask') == mask for x in p.runs)}; whole output identical: {same}."


def syncwarp(p: Probe) -> str:
    rows = []
    for k, r in enumerate(p.runs):
        got, mask = p.buf(r, "got"), p.buf(r, "mask")
        ok = sum(got[i] == (i ^ 16) * 3 + 5 for i in range(32))
        rows.append([k, f"{ok}/32", " ".join(sorted({f'{m:08x}' for m in mask}))])
    return table(["run", "lanes that read the partner's value", "active masks after the barrier"], rows)


def addr(p: Probe) -> str:
    r = p.runs[0]
    info = p.buf(r, "info")
    rows = []
    for f, name in enumerate(ADDR_FIELDS):
        vals = [info[c * 64 + f] for c in range(4)]
        rows.append([name] + [f"0x{v:x}" for v in vals])
    loc = p.buf(r, "local_addr")
    strides = sorted({loc[i + 1] - loc[i] for i in range(31)})
    return table(["field", "CTA 0", "CTA 1", "CTA 2", "CTA 3"], rows) + \
        f"\n\nLocal addresses of lanes 0 and 1 in CTA 0: 0x{loc[0]:x}, 0x{loc[1]:x}; lane-to-lane strides: " \
        f"{', '.join(hex(s) for s in strides)}."


def lat(p: Probe, ops: list[str], nt: int) -> str:
    rows = []
    for i, op in enumerate(ops):
        per_run = [p.buf(r, "cycles")[i * nt:(i + 1) * nt] for r in p.runs]
        m = med([med(x) for x in per_run]) / REPS
        mx = med([max(x) for x in per_run]) / REPS
        rows.append([op, f"{m:.1f}", f"{mx:.1f}"] if nt > 1 else [op, f"{m:.1f}"])
    head = ["operation", "cycles per op (median lane)", "slowest lane"] if nt > 1 else ["operation", "cycles per op"]
    return table(head, rows) + f"\n\nMedian over {len(p.runs)} runs; {REPS} back-to-back operations per sample."


def setmaxnreg(p: Probe) -> str:
    inc_wait, dec_wait, dec_req, ctas = [], [], [], 0
    for r in p.runs:
        t, req = p.buf(r, "t"), p.buf(r, "req")
        for c in range(len(t) // 12):
            tc, rq = t[c * 12:(c + 1) * 12], req[c * 12:(c + 1) * 12]
            if not any(tc):
                continue
            ctas += 1
            inc_wait += [tc[w] - rq[w] for w in range(4, 12)]
            dec_wait += [tc[w] - rq[w] for w in range(4)]
            dec_req += rq[:4]
    return table(["CTA runs", "decrease issued at (median cycle)", "median decrease time", "median increase wait",
                  "max increase wait"],
                 [[ctas, med(dec_req), med(dec_wait), med(inc_wait), max(inc_wait)]]) + \
        "\n\nCycles (clock64, relative to the CTA's start). Warpgroups 1 and 2 issue the increase at once; warpgroup 0 " \
        "issues the decrease after the delay. An increase wait close to the cycle the decrease is issued at means the " \
        "increase waited for the registers the decrease gave back."


def bmov_break_expected(lane: int) -> tuple[int, int | None, int]:
    """nested: the flat index where the lane leaves the loop nest; call: the lane itself on lanes that skip the
    call (the others sum values other lanes change, so only "written" is checked); multi: which exit it took."""
    call = lane if lane % 3 == 0 else None
    multi = 1000 + lane - 18 if lane > 20 else 2000 + lane
    return lane * 2 + 1, call, multi


def bmov_break(p: Probe) -> str:
    rows = []
    for k, r in enumerate(p.runs):
        res, mask = p.buf(r, "res"), p.buf(r, "mask")
        ok = [0, 0, 0]
        for lane in range(32):
            e = bmov_break_expected(lane)
            ok[0] += res[lane] == e[0]
            ok[1] += res[32 + lane] != 0 if e[1] is None else res[32 + lane] == e[1]
            ok[2] += res[64 + lane] == e[2]
        ms = [" ".join(sorted({f"{mask[c * 32 + i]:08x}" for i in range(32)})) for c in range(3)]
        rows.append([k, *(f"{x}/32" for x in ok), *ms])
    return table(["run", "nested right", "call right", "multi right", "masks after nested", "after call",
                  "after multi"], rows)


def bmov_deep_expected(lane: int) -> int:
    """The kernel's sum on the CPU: v[] stays 0, so only the recursive call (reached when all 24 bits test true)
    contributes."""
    m = 0xFFFFFFFF

    def rec(x: int, d: int) -> int:
        if d == 0:
            return x
        if (x >> (d & 7)) & 1:
            return rec((x * 7 + 1) & m, d - 1)
        return rec(x ^ d, d - 1)

    x = (lane * 2654435761) & m
    return rec(x, 6) if all((x >> d) & 1 for d in range(24)) else 0


def bmov_deep(p: Probe) -> str:
    rows = []
    for k, r in enumerate(p.runs):
        res, mask = p.buf(r, "res"), p.buf(r, "mask")
        ok = sum(res[lane] == bmov_deep_expected(lane) for lane in range(32))
        outer = sorted({f"{mask[0 * 32 + i]:08x}" for i in range(32)})
        rows.append([k, f"{ok}/32", " ".join(outer)])
    return table(["run", "lanes with the right sum", "active masks after the outermost level"], rows)


DECODERS = {
    "its-lock-in-warp": its_lock, "its-lock-in-loop": its_lock, "its-cross-branch-wait": its_cross,
    "its-producer-consumer": its_pc, "reconv-points": reconv, "syncwarp-divergent": syncwarp,
    "addr-windows": addr, "lat-scopes-1": lambda p: lat(p, LAT_OPS, 1),
    "lat-scopes-warp-same": lambda p: lat(p, LAT_OPS, 32), "lat-scopes-warp-distinct": lambda p: lat(p, LAT_OPS, 32),
    "lat-warp": lambda p: lat(p, WARP_OPS, 32), "setmaxnreg-nodelay": setmaxnreg, "setmaxnreg-delay": setmaxnreg,
    "bmov-break": bmov_break, "bmov-deep": bmov_deep,
}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("job", type=Path)
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args(argv)
    parts = [f"# Probe results: {a.job.name}\n"]
    for name, fn in DECODERS.items():
        if not (a.job / "goldens" / name).exists():
            parts.append(f"## {name}\n\nnot in this job\n")
            continue
        p = Probe(a.job, name)
        body = fn(p) if p.runs and p.result.startswith("ok") else f"no usable runs (result: {p.result})"
        parts.append(f"## {name}\n\nRunner result: `{p.result}`, {len(p.runs)} runs.\n\n{body}\n")
    text = "\n".join(parts)
    print(text)
    if a.write:
        (a.job / "results.md").write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

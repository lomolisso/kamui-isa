#!/usr/bin/env python3
"""Compile, check and (re)generate the PTX corpus entries in tests/corpus/.

For each entry directory (kernel.cu, or kernel.ll for features that only LLVM IR can express, plus entry.yaml) it
runs, inside the dev container:

    clang++-20 -x cuda --cuda-gpu-arch=sm_90a --cuda-device-only -S -O2 --cuda-feature=+ptx87 \
      --cuda-path=/usr/local/cuda -Wno-unknown-cuda-version <extra_flags> -o kernel.ptx kernel.cu
    ptxas -arch=sm_90a -v -o /dev/null kernel.ptx

(for kernel.ll: llc-20 -mtriple=nvptx64-nvidia-cuda -mcpu=sm_90a -mattr=+ptx87). It fails when clang or ptxas
fails, when the kernel entry point is missing, when an `expect_ptx` regex does not match kernel.ptx, when an
`expect_ptxas` regex does not match the ptxas -v output, when a floating-point entry does not state its
contraction and flush-to-zero flags, or (with --check) when the PTX it produces differs from the committed
kernel.ptx.

    python tools/corpus/build.py --all                 # rebuild every entry, rewrite kernel.ptx
    python tools/corpus/build.py --all --check         # rebuild into build/corpus, compare, write nothing
    python tools/corpus/build.py tests/corpus/xkmwarp/shfl.sync.bfly   # some entries
    python tools/corpus/build.py --all --lint          # no compiler: check entry.yaml against the committed PTX
    python tools/corpus/build.py --all --nvcc          # evidence only: nvcc's PTX of the same sources, in build/
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
CORPUS = ROOT / "tests" / "corpus"
BUILD = ROOT / "build" / "corpus"
CLANG = os.environ.get("KAMUI_CLANG", "clang++-20")
LLC = os.environ.get("KAMUI_LLC", "llc-20")
NVCC = os.environ.get("KAMUI_NVCC", "nvcc")
BUILD_NVCC = ROOT / "build" / "corpus-nvcc"
PTXAS = os.environ.get("KAMUI_PTXAS", "ptxas")
CUDA = os.environ.get("KAMUI_CUDA", "/usr/local/cuda")

COMMON_FLAGS = ["-x", "cuda", "--cuda-gpu-arch=sm_90a", "--cuda-device-only", "-S", "-O2",
                "--cuda-feature=+ptx87", f"--cuda-path={CUDA}", "-Wno-unknown-cuda-version"]

DTYPES = {"u8": 1, "s8": 1, "u16": 2, "s16": 2, "f16": 2, "bf16": 2, "u32": 4, "s32": 4, "f32": 4,
          "u64": 8, "s64": 8, "f64": 8}
PARAM_KINDS = ("input", "output", "inout", "scalar", "tensormap")
TENSORMAP_MODES = ("tile", "im2col")
GENERATORS = ("iota", "const", "random", "file")
ENTRY_KEYS = {"id", "kernel", "compile", "launch", "params", "expect_ptx", "expect_ptxas", "deterministic",
              "tolerance_class", "run", "notes"}
TOLERANCE_RE = re.compile(r"^(exact|ftz|reduction|ulp:\d+|property:[a-z_]+)$")

# An arithmetic or conversion instruction on a floating-point type: such entries must pin their FP flags.
FP_INSN_RE = re.compile(
    r"^\s*(?:@!?%\w+\s+)?(?:add|sub|mul|fma|mad|div|rcp|sqrt|rsqrt|sin|cos|lg2|ex2|tanh|min|max|abs|neg|cvt|setp|set"
    r"|testp|copysign|atom|red)(?:\.[\w:]+)*\.(?:f16|f16x2|bf16|bf16x2|f32|f64)\b", re.M)
CONTRACT_RE = re.compile(r"^-ffp-contract=(on|off|fast)$")
FTZ_FLAGS = {"-fcuda-flush-denormals-to-zero", "-fno-cuda-flush-denormals-to-zero"}


class EntryError(Exception):
    pass


def load_entry(d: Path) -> dict:
    p = d / "entry.yaml"
    if not p.is_file():
        raise EntryError(f"{d}: no entry.yaml")
    e = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    validate_entry(e, d)
    return e


def validate_entry(e: dict, d: Path) -> None:
    errs = []
    for k in e:
        if k not in ENTRY_KEYS:
            errs.append(f"unknown field {k}")
    for k in ("id", "kernel", "launch", "params", "expect_ptx", "deterministic", "tolerance_class"):
        if k not in e:
            errs.append(f"missing field {k}")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(e.get("kernel", ""))):
        errs.append("kernel must be a C identifier (the extern \"C\" name)")
    launch = e.get("launch") or {}
    for k in ("grid", "block"):
        v = launch.get(k)
        if not (isinstance(v, list) and len(v) == 3 and all(isinstance(x, int) and x > 0 for x in v)):
            errs.append(f"launch.{k} must be three positive integers")
    c = launch.get("cluster")
    if c is not None and not (isinstance(c, list) and len(c) == 3 and all(isinstance(x, int) and x > 0 for x in c)):
        errs.append("launch.cluster must be null or three positive integers")
    if not isinstance(launch.get("dynamic_smem", 0), int):
        errs.append("launch.dynamic_smem must be an integer")
    for i, p in enumerate(e.get("params") or []):
        where = f"params[{i}] ({p.get('name', '?')})"
        if p.get("kind") not in PARAM_KINDS:
            errs.append(f"{where}: kind must be one of {PARAM_KINDS}")
        if p.get("dtype") not in DTYPES:
            errs.append(f"{where}: dtype must be one of {sorted(DTYPES)}")
        if p.get("kind") == "scalar":
            if "value" not in p:
                errs.append(f"{where}: a scalar needs a value")
        elif p.get("kind") == "tensormap":
            buffers = [q.get("name") for q in (e.get("params") or [])[:i] if q.get("kind") in ("input", "output", "inout")]
            if p.get("of") not in buffers:
                errs.append(f"{where}: a tensormap names an earlier buffer parameter in `of`")
            if p.get("mode") not in TENSORMAP_MODES:
                errs.append(f"{where}: mode must be one of {TENSORMAP_MODES}")
            dims, box = p.get("dims"), p.get("box")
            if not (isinstance(dims, list) and isinstance(box, list) and 1 <= len(dims) <= 5 and len(dims) == len(box)):
                errs.append(f"{where}: dims and box are lists of 1 to 5 sizes, innermost first")
        else:
            if not (isinstance(p.get("count"), int) and p["count"] > 0):
                errs.append(f"{where}: count must be a positive integer")
            if p.get("kind") in ("input", "inout"):
                g = p.get("generator") or {}
                if g.get("kind") not in GENERATORS:
                    errs.append(f"{where}: generator.kind must be one of {GENERATORS}")
                if g.get("kind") == "random" and not all(k in g for k in ("seed", "low", "high")):
                    errs.append(f"{where}: a random generator needs seed, low and high")
                if g.get("kind") == "file" and not (d / str(g.get("path", ""))).is_file():
                    errs.append(f"{where}: generator file {g.get('path')} does not exist")
    if not (isinstance(e.get("expect_ptx"), list) and e["expect_ptx"]):
        errs.append("expect_ptx must be a non-empty list of regexes")
    for rx in (e.get("expect_ptx") or []) + (e.get("expect_ptxas") or []):
        try:
            re.compile(rx)
        except re.error as x:
            errs.append(f"bad regex {rx!r}: {x}")
    if not TOLERANCE_RE.match(str(e.get("tolerance_class", ""))):
        errs.append("tolerance_class must be exact, ftz, reduction, ulp:<n> or property:<name>")
    if e.get("deterministic") is False and not str(e.get("tolerance_class", "")).startswith("property:"):
        errs.append("a non-deterministic entry needs a property: tolerance")
    if e.get("run") is False and not e.get("notes"):
        errs.append("a compile-only entry (run: false) needs the reason in notes")
    if errs:
        raise EntryError(f"{d}: " + "; ".join(errs))


def extra_flags(e: dict) -> list[str]:
    return list((e.get("compile") or {}).get("extra_flags") or [])


def ptxas_flags(e: dict) -> list[str]:
    return list((e.get("compile") or {}).get("ptxas_flags") or [])


def compile_entry(d: Path, out_ptx: Path, e: dict) -> None:
    out_ptx.parent.mkdir(parents=True, exist_ok=True)
    has_cu, has_ll = (d / "kernel.cu").is_file(), (d / "kernel.ll").is_file()
    if has_cu == has_ll:
        raise EntryError(f"{d}: needs exactly one of kernel.cu and kernel.ll")
    if has_cu:
        cmd = [CLANG, *COMMON_FLAGS, *extra_flags(e), f"-fdebug-prefix-map={d}=.", "-o", str(out_ptx), "kernel.cu"]
    else:
        cmd = [LLC, "-mtriple=nvptx64-nvidia-cuda", "-mcpu=sm_90a", "-mattr=+ptx87", "-O2", *extra_flags(e),
               "-o", str(out_ptx), "kernel.ll"]
    r = subprocess.run(cmd, cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        raise EntryError(f"{d}: {Path(cmd[0]).name} failed:\n{r.stderr.strip()}")


def run_ptxas(ptx: Path, flags: list[str] | None = None) -> str:
    r = subprocess.run([PTXAS, "-arch=sm_90a", "-v", *(flags or []), "-o", os.devnull, str(ptx)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise EntryError(f"{ptx}: ptxas failed:\n{r.stderr.strip()}")
    return r.stdout + r.stderr


def check_ptx(d: Path, e: dict, ptx: str, ptxas_out: str | None) -> None:
    """ptxas_out None: skip the expect_ptxas checks (no ptxas available)."""
    errs = []
    if not re.search(r"\.entry\s+" + re.escape(e["kernel"]) + r"\s*\(", ptx):
        errs.append(f"no .entry {e['kernel']} in kernel.ptx (use extern \"C\" __global__)")
    for rx in e["expect_ptx"]:
        if not re.search(rx, ptx, re.M):
            errs.append(f"expect_ptx {rx!r} does not match kernel.ptx")
    for rx in (e.get("expect_ptxas") or []) if ptxas_out is not None else []:
        if not re.search(rx, ptxas_out, re.M):
            errs.append(f"expect_ptxas {rx!r} does not match the ptxas -v output")
    if FP_INSN_RE.search(ptx) and (d / "kernel.cu").is_file():
        flags = extra_flags(e)
        if not any(CONTRACT_RE.match(f) for f in flags) or not FTZ_FLAGS & set(flags):
            errs.append("floating-point entry: extra_flags must state -ffp-contract=on|off and "
                        "-fcuda-flush-denormals-to-zero or -fno-cuda-flush-denormals-to-zero")
    if errs:
        raise EntryError(f"{d}: " + "; ".join(errs))


def lint_one(d: Path) -> tuple[str, str | None]:
    """Checks that need no compiler: entry.yaml, and its expectations against the committed kernel.ptx."""
    try:
        e = load_entry(d)
        ptx = d / "kernel.ptx"
        if not ptx.is_file():
            raise EntryError(f"{d}: kernel.ptx is not committed")
        check_ptx(d, e, ptx.read_text(encoding="utf-8"), None)
        return str(d), None
    except EntryError as x:
        return str(d), str(x)


def build_one(d: Path, check: bool) -> tuple[str, str | None]:
    """Returns (entry directory, error message or None)."""
    try:
        e = load_entry(d)
        rel = d.relative_to(CORPUS)
        tmp = BUILD / rel / "kernel.ptx"
        compile_entry(d, tmp, e)
        ptx = tmp.read_text(encoding="utf-8")
        ptxas_out = run_ptxas(tmp, ptxas_flags(e))
        (BUILD / rel / "ptxas-v.txt").write_text(ptxas_out, encoding="utf-8")
        check_ptx(d, e, ptx, ptxas_out)
        committed = d / "kernel.ptx"
        if check:
            if not committed.is_file():
                raise EntryError(f"{d}: kernel.ptx is not committed")
            if committed.read_text(encoding="utf-8") != ptx:
                raise EntryError(f"{d}: kernel.ptx differs from the clang output (run build.py without --check)")
        else:
            shutil.copyfile(tmp, committed)
        return str(rel), None
    except EntryError as x:
        return str(d), str(x)


def nvcc_one(d: Path) -> tuple[str, str | None]:
    """Evidence only: nvcc's PTX for the same kernel.cu, written to build/corpus-nvcc/, never committed."""
    rel = d.relative_to(CORPUS)
    if not (d / "kernel.cu").is_file():
        return str(rel), None
    out = BUILD_NVCC / rel / "kernel.ptx"
    out.parent.mkdir(parents=True, exist_ok=True)
    flags = [f for f in extra_flags(load_entry(d)) if f in ("-ffp-contract=off", "-ffp-contract=on")]
    fmad = ["-fmad=false"] if "-ffp-contract=off" in flags else []
    ftz = ["-ftz=true"] if "-fcuda-flush-denormals-to-zero" in extra_flags(load_entry(d)) else []
    r = subprocess.run([NVCC, "-arch=sm_90a", "-ptx", "-O3", *fmad, *ftz, "-o", str(out), "kernel.cu"], cwd=d,
                       capture_output=True, text=True)
    if r.returncode != 0:
        out.unlink(missing_ok=True)
        return str(rel), "nvcc failed: " + (r.stderr.strip().splitlines() or ["?"])[0]
    return str(rel), None


def find_entries(paths: list[str], all_: bool) -> list[Path]:
    if all_:
        return sorted(p.parent for p in CORPUS.glob("*/*/entry.yaml"))
    out = []
    for p in paths:
        d = Path(p).resolve()
        if not (d / "entry.yaml").is_file():
            raise SystemExit(f"{p}: not an entry directory (no entry.yaml)")
        out.append(d)
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("entries", nargs="*", help="entry directories")
    ap.add_argument("--all", action="store_true", help="every entry under tests/corpus/")
    ap.add_argument("--check", action="store_true", help="compare with the committed kernel.ptx, write nothing")
    ap.add_argument("--nvcc", action="store_true", help="evidence only: nvcc's PTX into build/corpus-nvcc/")
    ap.add_argument("--lint", action="store_true", help="no compiler: check entry.yaml and the committed kernel.ptx")
    ap.add_argument("-j", "--jobs", type=int, default=min(32, os.cpu_count() or 1))
    args = ap.parse_args(argv)
    dirs = find_entries(args.entries, args.all)
    if not dirs:
        print("no entries")
        return 1
    failed = 0
    if args.nvcc:
        with ProcessPoolExecutor(max_workers=args.jobs) as ex:
            res = list(ex.map(nvcc_one, dirs))
        bad = [f"{r}: {e}" for r, e in res if e]
        for line in bad:
            print(f"skip {line}")
        print(f"nvcc PTX for {len(dirs) - len(bad)} of {len(dirs)} entries in {BUILD_NVCC}")
        return 0
    if args.lint:
        results = map(lint_one, dirs)
    else:
        ex = ProcessPoolExecutor(max_workers=args.jobs)
        results = ex.map(build_one, dirs, [args.check] * len(dirs))
    for _rel, err in results:
        if err:
            failed += 1
            print(f"FAIL {err}")
    mode = " (lint)" if args.lint else " (check)" if args.check else ""
    print(f"{len(dirs) - failed} of {len(dirs)} entries ok{mode}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

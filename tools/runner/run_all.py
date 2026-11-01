#!/usr/bin/env python3
"""Run corpus entries on the GPU with the runner and write their golden outputs.

    python tools/runner/run_all.py --dry-run --all                 # no GPU: build every launch file, check layouts
    python tools/runner/run_all.py --all --runner build/runner/runner --out OUT --job-id ID
    python tools/runner/run_all.py tests/corpus/base/add.int --runner ... --out OUT

For each entry (compile-only entries, `run: false`, are skipped) it

1. writes inputs.bin with tools/corpus/gen_inputs.py (the generators are never reimplemented here);
2. writes launch files for the runner (format in runner.c) and runs it --runs times with the output buffers
   cleared to zero, and once more with them filled with 0xA5, under a timeout (a wrong mbarrier count hangs);
3. compares the runs: a deterministic entry must give identical bytes every time, and the bytes that differ
   between the zero-filled and the 0xA5-filled run are the bytes the kernel never wrote;
4. optionally runs compute-sanitizer (memcheck, racecheck) and the NVBit cubin dump of the JIT-compiled code;
5. writes OUT/goldens/<id>/outputs.bin (the first zero-filled run) and golden.yaml, and OUT/goldens/manifest.yaml.

<id> is the entry directory name. outputs.bin holds the output and inout buffers, in the order of `params`,
raw little-endian, no padding.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "corpus"))
import gen_inputs  # noqa: E402

CORPUS = ROOT / "tests" / "corpus"
SIZES = {"u8": 1, "s8": 1, "u16": 2, "s16": 2, "f16": 2, "bf16": 2, "u32": 4, "s32": 4, "f32": 4, "u64": 8, "s64": 8,
         "f64": 8}
POISON = 0xA5
RESULT_RE = re.compile(r"^result (\S+)(.*)$", re.M)


class LayoutError(Exception):
    pass


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def load(d: Path) -> dict:
    return yaml.safe_load((d / "entry.yaml").read_text())


def scalar_hex(p: dict) -> tuple[int, str]:
    n = SIZES[p["dtype"]]
    v = p["value"]
    if p["dtype"] in ("f32", "f64"):
        b = struct.pack("<f" if n == 4 else "<d", float(v))
    else:
        b = (int(v) % (1 << (8 * n))).to_bytes(n, "little")
    return n, b.hex()


def buffers(e: dict) -> list[dict]:
    """The buffer parameters with their sizes and offsets in inputs.bin and outputs.bin."""
    out, inoff, outoff = [], 0, 0
    for i, p in enumerate(e["params"]):
        if p["kind"] not in ("input", "output", "inout"):
            continue
        n = SIZES[p["dtype"]] * p["count"]
        b = {"index": i, "name": p["name"], "kind": p["kind"], "dtype": p["dtype"], "count": p["count"], "bytes": n,
             "in": inoff if p["kind"] in ("input", "inout") else -1,
             "out": outoff if p["kind"] in ("output", "inout") else -1}
        if b["in"] >= 0:
            inoff += n
        if b["out"] >= 0:
            outoff += n
        out.append(b)
    return out


def launch_file(d: Path, e: dict, module: Path, inputs: Path | None, outputs: Path, jitlog: Path | None,
                fill: int) -> str:
    """The runner's launch file for one entry. Raises LayoutError when the descriptor cannot be run."""
    L = e["launch"]
    ptx = (d / "kernel.ptx").read_text()
    cluster = L.get("cluster") or [0, 0, 0]
    if re.search(r"^\s*\.reqnctapercluster\b", ptx, re.M):
        cluster = [0, 0, 0]  # the cluster shape is fixed in the kernel; a launch attribute must not repeat it
    lines = [f"# {d.relative_to(ROOT)}", f"kernel {e['kernel']}", f"module {module}", f"inputs {inputs or '-'}",
             f"outputs {outputs}", f"jitlog {jitlog or '-'}", "grid {} {} {}".format(*L["grid"]),
             "block {} {} {}".format(*L["block"]), "cluster {} {} {}".format(*cluster),
             f"smem {L.get('dynamic_smem') or 0}", f"fill {fill}"]
    bufs = {b["index"]: b for b in buffers(e)}
    names = {p["name"]: i for i, p in enumerate(e["params"])}
    for i, p in enumerate(e["params"]):
        k = p["kind"]
        if k in ("input", "output", "inout"):
            b = bufs[i]
            lines.append(f"param buffer {b['bytes']} {b['in']} {1 if b['out'] >= 0 else 0}  # {p['name']}")
        elif k == "scalar":
            n, h = scalar_hex(p)
            lines.append(f"param scalar {n} {h}  # {p['name']} = {p['value']}")
        elif k == "tensormap":
            buf = names.get(p["of"])
            if buf is None or buf not in bufs:
                raise LayoutError(f"{p['name']}: `of` must name a buffer parameter")
            dims = list(p["dims"])
            whole = 1
            for x in dims:
                whole *= x
            if whole != bufs[buf]["count"]:
                raise LayoutError(f"{p['name']}: dims {dims} do not cover the {bufs[buf]['count']} elements of {p['of']}")
            tail = [p.get("swizzle", "none"), p.get("interleave", "none"), p.get("fill", "zero")]
            if p["mode"] == "tile":
                fields = ["tile", p["dtype"], buf, len(dims), *dims, *p["box"], *tail]
            else:
                lo, hi = p["pixel_box_lower"], p["pixel_box_upper"]
                if len(lo) != len(dims) - 2 or len(hi) != len(dims) - 2:
                    raise LayoutError(f"{p['name']}: im2col corners need rank - 2 values")
                fields = ["im2col", p["dtype"], buf, len(dims), *dims, *lo, *hi, p["channels_per_pixel"],
                          p["pixels_per_column"], *tail]
            lines.append("param tmap " + " ".join(str(x) for x in fields) + f"  # {p['name']}")
        else:
            raise LayoutError(f"unknown parameter kind {k}")
    return "\n".join(lines) + "\n"


def entry_dirs(paths: list[str], all_: bool) -> list[Path]:
    if all_:
        return sorted(p.parent for p in CORPUS.glob("*/*/entry.yaml"))
    return [Path(p).resolve() for p in paths]


def run(cmd: list[str], timeout: float, env: dict | None = None) -> tuple[str, str, float]:
    """Run a command; return (result word, detail, seconds). A timeout is reported as a launch error."""
    t = time.monotonic()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return "launch-error", f"timeout after {timeout:.0f} s", time.monotonic() - t
    m = RESULT_RE.findall(r.stdout)
    if not m:
        return "setup-error", (r.stderr.strip() or r.stdout.strip() or f"exit {r.returncode}")[-300:], \
            time.monotonic() - t
    word, detail = m[-1]
    return word, detail.strip(), time.monotonic() - t


def sanitizer(tool: str, runner: str, lf: Path, timeout: float, env: dict) -> str:
    """One line summarising a compute-sanitizer run."""
    cmd = ["compute-sanitizer", "--tool", tool, "--error-exitcode", "9", runner, str(lf)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout * 10, env=env)
    except subprocess.TimeoutExpired:
        return "timeout"
    out = r.stdout + r.stderr
    m = re.search(r"(ERROR SUMMARY: .*|RACECHECK SUMMARY: .*)", out)
    return m.group(1).strip() if m else f"exit {r.returncode}"


def unwritten(a: bytes, b: bytes) -> int:
    return sum(1 for x, y in zip(a, b) if x != y)


def gpu_info() -> dict:
    try:
        q = subprocess.run(["nvidia-smi", "--query-gpu=name,uuid,driver_version", "--format=csv,noheader"],
                           capture_output=True, text=True, check=True).stdout.strip().splitlines()[0]
        name, uuid, driver = (s.strip() for s in q.split(","))
        return {"name": name, "uuid": uuid, "driver": driver}
    except (OSError, subprocess.CalledProcessError, IndexError, ValueError):
        return {}


def run_entry(d: Path, args, work: Path, gold: Path, env: dict, gpu: dict) -> dict:
    e = load(d)
    eid = d.name
    rec = {"id": eid, "entry": str(d.relative_to(ROOT))}
    if e.get("run") is False:
        rec["result"] = "skipped: compile-only entry"
        return rec
    w = work / eid
    w.mkdir(parents=True, exist_ok=True)
    inputs = gen_inputs.inputs_bin(d)
    (w / "inputs.bin").write_bytes(inputs)
    module = Path(args.cubin_dir) / f"{eid}.cubin" if args.cubin_dir else d / "kernel.ptx"
    files = []
    for k in range(args.runs):
        files.append((w / f"run{k}.launch", w / f"run{k}.bin", 0))
    files.append((w / "poison.launch", w / "poison.bin", POISON))
    for lf, ob, fill in files:
        lf.write_text(launch_file(d, e, module, w / "inputs.bin", ob, w / "jit.log" if fill == 0 else None, fill))
    expect = sum(b["bytes"] for b in buffers(e) if b["in"] >= 0)
    if expect != len(inputs):
        raise LayoutError(f"inputs.bin has {len(inputs)} bytes, the parameters need {expect}")
    if args.dry_run:
        rec["result"] = "dry-run"
        if args.parse_check:
            word, detail, _ = run([args.runner, "--parse-only", str(files[0][0])], args.timeout, env)
            if word != "parsed":
                raise LayoutError(f"the runner cannot parse the launch file: {word} {detail}")
            rec["result"] = "dry-run parsed"
        return rec
    results = [run([args.runner, str(lf)], args.timeout, env) for lf, _, _ in files]
    rec["seconds"] = round(sum(t for _, _, t in results), 2)
    first = results[0]
    rec["result"] = first[0] if not first[1] else f"{first[0]} {first[1]}"
    outs = [ob.read_bytes() if ob.exists() and res[0] == "ok" else None for (_, ob, _), res in zip(files, results)]
    det = e.get("deterministic", True)
    runs = outs[:-1]
    rec["runs_identical"] = all(o is not None and o == runs[0] for o in runs)
    rec["deterministic"] = det
    if det and not rec["runs_identical"] and first[0] == "ok":
        rec["flag"] = "deterministic entry gave different outputs"
    g = gold / eid
    if g.exists():
        shutil.rmtree(g)
    g.mkdir(parents=True)
    golden = {
        "feature": e["id"], "entry": rec["entry"],
        "ptx_sha256": sha256((d / "kernel.ptx").read_bytes()),
        "inputs_sha256": sha256(inputs),
        "load_path": "cubin" if args.cubin_dir else "jit",
        "gpu": gpu, "job_id": args.job_id,
        "launch": {k: e["launch"].get(k) for k in ("grid", "block", "cluster", "dynamic_smem")},
        "result": rec["result"],
        "deterministic": det, "runs": args.runs, "runs_identical": rec["runs_identical"],
        "tolerance": e["tolerance_class"],
    }
    if outs[0] is not None:
        (g / "outputs.bin").write_bytes(outs[0])
        golden["outputs_sha256"] = sha256(outs[0])
        golden["outputs"] = []
        for b in buffers(e):
            if b["out"] < 0:
                continue
            chunk = outs[0][b["out"]: b["out"] + b["bytes"]]
            o = {"name": b["name"], "dtype": b["dtype"], "count": b["count"], "offset": b["out"], "bytes": b["bytes"],
                 "sha256": sha256(chunk)}
            if det and outs[-1] is not None:
                o["unwritten_bytes"] = unwritten(chunk, outs[-1][b["out"]: b["out"] + b["bytes"]])
            golden["outputs"].append(o)
    if (w / "jit.log").exists():
        m = re.search(r"Used (\d+) registers", (w / "jit.log").read_text())
        if m:
            golden["jit_registers"] = int(m.group(1))
    if args.sanitizer:
        golden["sanitizer"] = {t: sanitizer(t, args.runner, files[0][0], args.timeout, env) for t in args.sanitizer}
    if args.nvbit_dump and first[0] == "ok":
        dump = w / "cubin"
        dump.mkdir(exist_ok=True)
        run([args.runner, str(files[0][0])], args.timeout,
            {**env, "LD_PRELOAD": args.nvbit_dump, "DUMP_CUBIN_DIR": str(dump), "TOOL_VERBOSE": "0"})
        cubins = sorted(dump.glob("*.cubin"))
        if cubins and args.jit_sass_dir:
            Path(args.jit_sass_dir).mkdir(parents=True, exist_ok=True)
            r = subprocess.run(["nvdisasm", "-json", str(cubins[0])], capture_output=True, text=True)
            if r.returncode == 0:
                (Path(args.jit_sass_dir) / f"{eid}.json").write_text(r.stdout)
        golden["jit_cubin_dumped"] = bool(cubins)
    (g / "golden.yaml").write_text(yaml.safe_dump(golden, sort_keys=False, width=120))
    rec["golden"] = golden
    return rec


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("entries", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="no GPU: write launch files and check layouts only")
    ap.add_argument("--parse-check", action="store_true", help="with --dry-run: also run `runner --parse-only`")
    ap.add_argument("--runner", default=str(ROOT / "build" / "runner" / "runner"))
    ap.add_argument("--out", default=str(ROOT / "build" / "goldens"), help="goldens/ and work/ go here")
    ap.add_argument("--job-id", default="")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--cubin-dir", help="load <id>.cubin from here instead of the PTX (offline-cubin cross-check)")
    ap.add_argument("--sanitizer", type=lambda s: [t for t in s.split(",") if t], default=[],
                    help="comma-separated compute-sanitizer tools, for example memcheck,racecheck")
    ap.add_argument("--nvbit-dump", help="NVBit tool that dumps the JIT cubin (DUMP_CUBIN_DIR)")
    ap.add_argument("--jit-sass-dir", help="where to write nvdisasm -json of the JIT cubins")
    args = ap.parse_args(argv)
    dirs = entry_dirs(args.entries, args.all)
    out = Path(args.out)
    work, gold = out / "work", out / "goldens"
    gold.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "CUDA_CACHE_DISABLE": "1"}
    gpu = {} if args.dry_run else gpu_info()
    recs, bad = [], 0
    for d in dirs:
        try:
            rec = run_entry(d, args, work, gold, env, gpu)
        except (LayoutError, KeyError, ValueError) as x:
            rec = {"id": d.name, "entry": str(d.relative_to(ROOT)), "result": f"layout-error {x}"}
            bad += 1
        recs.append(rec)
        flag = f"  FLAG: {rec['flag']}" if rec.get("flag") else ""
        print(f"{rec['id']:40s} {rec['result']}{flag}", flush=True)
    if not args.dry_run:
        manifest = {"job_id": args.job_id, "gpu": gpu, "entries": []}
        for r in recs:
            m = {"id": r["id"], "result": r["result"]}
            g = gold / r["id"]
            for f in ("golden.yaml", "outputs.bin"):
                if (g / f).exists():
                    m[f.replace(".", "_") + "_sha256"] = sha256((g / f).read_bytes())
            if r.get("flag"):
                m["flag"] = r["flag"]
            manifest["entries"].append(m)
        (gold / "manifest.yaml").write_text(yaml.safe_dump(manifest, sort_keys=False, width=120))
    counts: dict[str, int] = {}
    for r in recs:
        counts[r["result"].split()[0].rstrip(":")] = counts.get(r["result"].split()[0].rstrip(":"), 0) + 1
    print("summary: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

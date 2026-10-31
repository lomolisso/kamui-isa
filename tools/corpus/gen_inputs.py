#!/usr/bin/env python3
"""Write inputs.bin for corpus entries from the seeded generators in their entry.yaml.

inputs.bin holds the initial contents of every `input` and `inout` buffer, in the order of `params`, as raw
little-endian data with no padding. Generators run only here; the H100 runner, the simulator and the
conformance runner read inputs.bin and never reimplement them.

Generators:
- `iota`: start + i * step (defaults 0 and 1).
- `const`: every element is `value`.
- `random`: uniform in [low, high] for integer types, [low, high) for floating-point types, from
  numpy.random.Generator(PCG64(seed)).
- `file`: the raw bytes of a file in the entry directory (its size must match count * element size).

    python tools/corpus/gen_inputs.py --all                     # build/corpus/<family>/<entry>/inputs.bin
    python tools/corpus/gen_inputs.py tests/corpus/base/add.int -o /tmp/x.bin
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import yaml

ROOT = Path(__file__).resolve().parents[2]
CORPUS = ROOT / "tests" / "corpus"
BUILD = ROOT / "build" / "corpus"

NUMPY = {"u8": np.uint8, "s8": np.int8, "u16": np.uint16, "s16": np.int16, "u32": np.uint32, "s32": np.int32,
         "u64": np.uint64, "s64": np.int64, "f16": np.float16, "f32": np.float32, "f64": np.float64}
FLOAT = {"f16", "bf16", "f32", "f64"}


def to_bf16(x: np.ndarray) -> np.ndarray:
    """f32 values to bf16 bit patterns (uint16), round to nearest even."""
    bits = np.asarray(x, dtype=np.float32).view(np.uint32).astype(np.uint64)
    rounded = (bits + 0x7FFF + ((bits >> 16) & 1)) >> 16
    return rounded.astype(np.uint16)


def generate(param: dict, entry_dir: Path) -> bytes:
    dtype, n, g = param["dtype"], param["count"], param["generator"]
    kind = g["kind"]
    if kind == "file":
        data = (entry_dir / g["path"]).read_bytes()
        size = 2 if dtype == "bf16" else np.dtype(NUMPY[dtype]).itemsize
        if len(data) != n * size:
            raise ValueError(f"{g['path']}: {len(data)} bytes, expected {n * size}")
        return data
    if kind == "iota":
        values = g.get("start", 0) + np.arange(n, dtype=np.float64 if dtype in FLOAT else np.int64) * g.get("step", 1)
    elif kind == "const":
        values = np.full(n, float(g["value"]) if dtype in FLOAT else int(g["value"]),
                         dtype=np.float64 if dtype in FLOAT else object)
    elif kind == "random":
        rng = np.random.Generator(np.random.PCG64(g["seed"]))
        if dtype in FLOAT:
            values = rng.uniform(float(g["low"]), float(g["high"]), n)
        else:
            values = rng.integers(int(g["low"]), int(g["high"]), n, endpoint=True, dtype=np.int64
                                  if dtype != "u64" else np.uint64)
    else:
        raise ValueError(f"unknown generator {kind}")
    if dtype == "bf16":
        return to_bf16(np.asarray(values, dtype=np.float32)).astype("<u2").tobytes()
    t = np.dtype(NUMPY[dtype]).newbyteorder("<")
    if dtype in FLOAT:
        return np.asarray(values, dtype=np.float64).astype(t).tobytes()
    # integers wrap modulo 2^bits, so negative constants work for unsigned types
    unsigned = np.dtype(f"<u{t.itemsize}")
    ints = [int(v) % (1 << (8 * t.itemsize)) for v in values]
    return np.array(ints, dtype=unsigned).view(t).tobytes()


def inputs_bin(entry_dir: Path) -> bytes:
    e = yaml.safe_load((entry_dir / "entry.yaml").read_text(encoding="utf-8"))
    return b"".join(generate(p, entry_dir) for p in e["params"] if p["kind"] in ("input", "inout"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("entries", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("-o", "--output", type=Path, help="output file (one entry only)")
    args = ap.parse_args(argv)
    dirs = sorted(p.parent for p in CORPUS.glob("*/*/entry.yaml")) if args.all else [Path(p).resolve() for p in args.entries]
    if args.output and len(dirs) != 1:
        raise SystemExit("-o needs exactly one entry")
    for d in dirs:
        out = args.output or BUILD / d.relative_to(CORPUS) / "inputs.bin"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(inputs_bin(d))
    print(f"wrote inputs.bin for {len(dirs)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())

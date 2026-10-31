"""Unit tests of build.py and gen_inputs.py. The compile test needs clang 20 and ptxas (dev container) and is
skipped without them."""

import shutil
import struct
from pathlib import Path

import numpy as np
import pytest
import yaml

import build
import gen_inputs

ENTRY = {
    "id": "x.test",
    "kernel": "k_x",
    "compile": {"extra_flags": []},
    "launch": {"grid": [1, 1, 1], "block": [32, 1, 1], "cluster": None, "dynamic_smem": 0},
    "params": [
        {"name": "a", "kind": "input", "dtype": "s32", "count": 4, "generator": {"kind": "iota", "start": -2}},
        {"name": "c", "kind": "inout", "dtype": "u16", "count": 2, "generator": {"kind": "const", "value": -1}},
        {"name": "d", "kind": "output", "dtype": "s32", "count": 4},
        {"name": "n", "kind": "scalar", "dtype": "s32", "value": 4},
    ],
    "expect_ptx": [r"add\.s32"],
    "deterministic": True,
    "tolerance_class": "exact",
}

PTX = """.version 8.7
.target sm_90a
.address_size 64
.visible .entry k_x(.param .u64 k_x_param_0)
{
	add.s32 	%r1, %r2, %r3;
	ret;
}
"""


def make_entry(tmp_path: Path, entry: dict, ptx: str = PTX) -> Path:
    d = tmp_path / "fam" / "x.test"
    d.mkdir(parents=True)
    (d / "entry.yaml").write_text(yaml.safe_dump(entry))
    (d / "kernel.ptx").write_text(ptx)
    return d


def test_validate_accepts_a_good_entry(tmp_path):
    d = make_entry(tmp_path, ENTRY)
    assert build.load_entry(d)["id"] == "x.test"
    assert build.lint_one(d)[1] is None


@pytest.mark.parametrize("change, message", [
    ({"tolerance_class": "loose"}, "tolerance_class"),
    ({"deterministic": False}, "property"),
    ({"run": False}, "compile-only"),
    ({"kernel": "k-x"}, "C identifier"),
    ({"launch": {"grid": [1, 1], "block": [32, 1, 1]}}, "launch.grid"),
    ({"expect_ptx": []}, "expect_ptx"),
    ({"surprise": 1}, "unknown field"),
])
def test_validate_rejects(tmp_path, change, message):
    d = make_entry(tmp_path, {**ENTRY, **change})
    with pytest.raises(build.EntryError, match=message):
        build.load_entry(d)


def test_lint_checks_ptx(tmp_path):
    d = make_entry(tmp_path, {**ENTRY, "expect_ptx": [r"sub\.s32"]})
    assert "does not match" in build.lint_one(d)[1]
    d2 = make_entry(tmp_path / "b", ENTRY, PTX.replace("k_x(", "k_y("))
    assert "no .entry k_x" in build.lint_one(d2)[1]


def test_fp_entries_must_pin_flags(tmp_path):
    fp = PTX.replace("add.s32", "add.rn.f32")
    d = make_entry(tmp_path, {**ENTRY, "expect_ptx": [r"add\.rn\.f32"]}, fp)
    (d / "kernel.cu").write_text("")
    assert "floating-point entry" in build.lint_one(d)[1]
    e = {**ENTRY, "expect_ptx": [r"add\.rn\.f32"],
         "compile": {"extra_flags": ["-ffp-contract=off", "-fno-cuda-flush-denormals-to-zero"]}}
    (d / "entry.yaml").write_text(yaml.safe_dump(e))
    assert build.lint_one(d)[1] is None


def test_inputs_bin(tmp_path):
    d = make_entry(tmp_path, ENTRY)
    data = gen_inputs.inputs_bin(d)
    assert data == struct.pack("<4i", -2, -1, 0, 1) + struct.pack("<2H", 0xFFFF, 0xFFFF)


def test_random_generator_is_reproducible(tmp_path):
    p = {"dtype": "f32", "count": 5, "generator": {"kind": "random", "seed": 7, "low": -1.0, "high": 1.0}}
    a = gen_inputs.generate(p, tmp_path)
    assert a == gen_inputs.generate(p, tmp_path)
    expect = np.random.Generator(np.random.PCG64(7)).uniform(-1.0, 1.0, 5).astype("<f4").tobytes()
    assert a == expect
    q = {"dtype": "u64", "count": 3, "generator": {"kind": "random", "seed": 1, "low": 0, "high": (1 << 64) - 1}}
    assert len(gen_inputs.generate(q, tmp_path)) == 24


def test_bf16_rounding():
    x = np.array([1.0, 1.00390625, 1.01171875, -2.5], dtype=np.float32)
    assert list(gen_inputs.to_bf16(x)) == [0x3F80, 0x3F80, 0x3F82, 0xC020]


@pytest.mark.skipif(shutil.which(build.CLANG) is None or shutil.which(build.PTXAS) is None,
                    reason="clang 20 and ptxas are only in the dev container")
def test_compile_one_entry(tmp_path, monkeypatch):
    monkeypatch.setattr(build, "CORPUS", tmp_path)
    monkeypatch.setattr(build, "BUILD", tmp_path / "build")
    d = tmp_path / "fam" / "x.test"
    d.mkdir(parents=True)
    (d / "kernel.cu").write_text('extern "C" __global__ void k_x(const int *a, int *d) {\n'
                                 '  d[threadIdx.x] = a[threadIdx.x] + 1;\n}\n')
    (d / "entry.yaml").write_text(yaml.safe_dump({**ENTRY, "params": ENTRY["params"][:1] + ENTRY["params"][2:3]}))
    assert build.build_one(d, check=False) == ("fam/x.test", None)
    assert build.build_one(d, check=True) == ("fam/x.test", None)
    (d / "kernel.ptx").write_text("changed")
    assert "differs" in build.build_one(d, check=True)[1]

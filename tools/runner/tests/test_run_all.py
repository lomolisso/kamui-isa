"""Unit tests of run_all.py: launch files and buffer layouts (no GPU, no runner binary needed)."""

from pathlib import Path

import pytest
import yaml

import run_all

ROOT = Path(__file__).resolve().parents[3]


def entry(tmp_path: Path, params: list, ptx: str = ".version 8.7\n", cluster=None) -> tuple[Path, dict]:
    d = tmp_path / "x.test"
    d.mkdir()
    e = {"id": "x.test", "kernel": "k_x", "launch": {"grid": [2, 1, 1], "block": [64, 1, 1], "cluster": cluster,
                                                     "dynamic_smem": 0},
         "params": params, "tolerance_class": "exact", "deterministic": True}
    (d / "entry.yaml").write_text(yaml.safe_dump(e))
    (d / "kernel.ptx").write_text(ptx)
    return d, e


def lines(text: str, prefix: str) -> list[str]:
    return [ln.split("#")[0].strip() for ln in text.splitlines() if ln.startswith(prefix)]


def test_buffers_scalars_and_offsets(tmp_path, monkeypatch):
    monkeypatch.setattr(run_all, "ROOT", tmp_path)
    d, e = entry(tmp_path, [
        {"name": "a", "kind": "input", "dtype": "s32", "count": 4, "generator": {"kind": "iota"}},
        {"name": "c", "kind": "inout", "dtype": "u16", "count": 2, "generator": {"kind": "const", "value": 1}},
        {"name": "d", "kind": "output", "dtype": "f64", "count": 3},
        {"name": "n", "kind": "scalar", "dtype": "s32", "value": -2},
        {"name": "p", "kind": "scalar", "dtype": "u64", "value": 65536}])
    text = run_all.launch_file(d, e, d / "kernel.ptx", None, tmp_path / "o.bin", None, 0xA5)
    assert lines(text, "param") == ["param buffer 16 0 0", "param buffer 4 16 1", "param buffer 24 -1 1",
                                    "param scalar 4 feffffff", "param scalar 8 0000010000000000"]
    assert "fill 165" in text and "cluster 0 0 0" in text
    assert [(b["name"], b["in"], b["out"]) for b in run_all.buffers(e)] == [("a", 0, -1), ("c", 16, 0), ("d", -1, 4)]


def test_tensor_maps_and_cluster(tmp_path, monkeypatch):
    monkeypatch.setattr(run_all, "ROOT", tmp_path)
    d, e = entry(tmp_path, [
        {"name": "g", "kind": "input", "dtype": "u32", "count": 512, "generator": {"kind": "iota"}},
        {"name": "tm", "kind": "tensormap", "of": "g", "dtype": "u32", "mode": "im2col", "dims": [8, 32, 2],
         "box": [8, 16, 1], "pixel_box_lower": [-1], "pixel_box_upper": [1], "channels_per_pixel": 8,
         "pixels_per_column": 16},
        {"name": "t2", "kind": "tensormap", "of": "g", "dtype": "u32", "mode": "tile", "dims": [64, 8], "box": [32, 8],
         "swizzle": "128B"}], cluster=[2, 1, 1])
    text = run_all.launch_file(d, e, d / "kernel.ptx", None, tmp_path / "o.bin", None, 0)
    assert lines(text, "param tmap") == ["param tmap im2col u32 0 3 8 32 2 -1 1 8 16 none none zero",
                                         "param tmap tile u32 0 2 64 8 32 8 128B none zero"]
    assert "cluster 2 1 1" in text


def test_compile_time_cluster_drops_the_launch_attribute(tmp_path, monkeypatch):
    monkeypatch.setattr(run_all, "ROOT", tmp_path)
    d, e = entry(tmp_path, [], ptx=".entry k_x()\n.explicitcluster\n.reqnctapercluster 2, 1, 1\n{ ret; }\n",
                 cluster=[2, 1, 1])
    assert "cluster 0 0 0" in run_all.launch_file(d, e, d / "kernel.ptx", None, tmp_path / "o", None, 0)


def test_tensor_map_must_cover_its_buffer(tmp_path, monkeypatch):
    monkeypatch.setattr(run_all, "ROOT", tmp_path)
    d, e = entry(tmp_path, [
        {"name": "g", "kind": "input", "dtype": "u32", "count": 100, "generator": {"kind": "iota"}},
        {"name": "tm", "kind": "tensormap", "of": "g", "dtype": "u32", "mode": "tile", "dims": [64, 2], "box": [8, 2]}])
    with pytest.raises(run_all.LayoutError):
        run_all.launch_file(d, e, d / "kernel.ptx", None, tmp_path / "o", None, 0)


def test_every_corpus_entry_has_a_launch_file(tmp_path):
    for d in sorted((ROOT / "tests" / "corpus").glob("*/*")):
        if not (d / "entry.yaml").exists():
            continue
        e = run_all.load(d)
        if e.get("run") is False:
            continue
        text = run_all.launch_file(d, e, d / "kernel.ptx", None, tmp_path / "o.bin", None, 0)
        assert f"kernel {e['kernel']}" in text

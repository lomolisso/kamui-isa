"""Unit tests of jit_probe.py against a fake libcuda (no GPU, no driver needed)."""

import ctypes
import io
import struct
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jit_probe  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
VECADD = ROOT / "tests" / "corpus" / "base" / "app.vecadd" / "kernel.ptx"
BAD = ROOT / "docs" / "examples" / "cuda" / "bad.ptx"
NAMES = {0: b"CUDA_SUCCESS", 218: b"CUDA_ERROR_INVALID_PTX", 222: b"CUDA_ERROR_UNSUPPORTED_PTX_VERSION"}


class FakeCuda:
    """Implements the libcuda calls the probe makes. load_rc is what cuModuleLoadDataEx returns; wrong_elems
    makes the fake kernel write a wrong value into that many output elements."""

    def __init__(self, load_rc=0, wrong_elems=0):
        self.load_rc, self.wrong = load_rc, wrong_elems
        self.mem, self.next_ptr, self.launch = {}, 0x1000, None
        self._names = {}

    def cuGetErrorName(self, rc, p):
        self._names[rc] = ctypes.c_char_p(NAMES.get(rc, b"CUDA_ERROR_OTHER"))
        p._obj.value = self._names[rc].value
        return 0

    def cuInit(self, flags):
        return 0

    def cuDriverGetVersion(self, p):
        p._obj.value = 13000
        return 0

    def cuDeviceGet(self, p, ordinal):
        p._obj.value = ordinal
        return 0

    def cuDeviceGetName(self, buf, size, dev):
        buf.value = b"Fake H100"
        return 0

    def cuDeviceGetAttribute(self, p, attr, dev):
        p._obj.value = {75: 9, 76: 0}[attr]
        return 0

    def cuCtxCreate_v2(self, p, flags, dev):
        p._obj.value = 1
        return 0

    def cuModuleLoadDataEx(self, p, text, n, opts, vals):
        assert n == 5 and list(opts) == [3, 4, 5, 6, 12]
        assert text.value.startswith(b"//") or b".version" in text.value
        log = b"ptxas info    : Used 8 registers" if self.load_rc == 0 else b"ptxas error   : bad"
        ctypes.memmove(vals[0] if self.load_rc == 0 else vals[2], log, len(log))
        p._obj.value = 7
        return self.load_rc

    def cuModuleGetFunction(self, p, mod, name):
        assert name == b"k_app_vecadd"
        p._obj.value = 9
        return 0

    def cuMemAlloc_v2(self, p, size):
        p._obj.value = self.next_ptr
        self.mem[self.next_ptr] = bytearray(size.value)
        self.next_ptr += 0x1000
        return 0

    def cuMemcpyHtoD_v2(self, dptr, src, size):
        self.mem[dptr.value][:] = ctypes.string_at(src, size.value)
        return 0

    def cuMemsetD8_v2(self, dptr, value, size):
        self.mem[dptr.value][:] = bytes([value]) * size.value
        return 0

    def cuLaunchKernel(self, fn, gx, gy, gz, bx, by, bz, smem, stream, args, extra):
        assert (gx, bx) == (4, 256)
        ptrs = [ctypes.cast(args[i], ctypes.POINTER(ctypes.c_uint64))[0] for i in range(3)]
        n = ctypes.cast(args[3], ctypes.POINTER(ctypes.c_int))[0]
        a = struct.unpack(f"<{n}f", self.mem[ptrs[0]])
        b = struct.unpack(f"<{n}f", self.mem[ptrs[1]])
        c = [x + y for x, y in zip(a, b)]
        for i in range(self.wrong):
            c[i] += 1.0
        self.mem[ptrs[2]][:] = struct.pack(f"<{n}f", *c)
        return 0

    def cuCtxSynchronize(self):
        return 0

    def cuMemcpyDtoH_v2(self, dst, dptr, size):
        ctypes.memmove(dst, bytes(self.mem[dptr.value]), size.value)
        return 0

    def cuMemFree_v2(self, dptr):
        return 0


def run(path, fake, **kw):
    out = io.StringIO()
    rc = jit_probe.probe(path, drv=jit_probe.Driver(fake), out=out, **kw)
    return rc, out.getvalue()


def test_header_of_committed_vecadd():
    h = jit_probe.ptx_header(VECADD.read_text())
    assert h == {"version": "8.7", "target": "sm_90a", "entry": "k_app_vecadd"}


def test_load_and_launch_ok():
    rc, out = run(VECADD, FakeCuda(), expect_fail=False, launch=True)
    assert rc == 0
    assert "cuModuleLoadDataEx: 0 (CUDA_SUCCESS)" in out
    assert "Used 8 registers" in out and "compute capability 9.0" in out and "driver api version: 13.0" in out
    assert "1000/1000 elements match" in out


def test_wrong_output_fails():
    rc, out = run(VECADD, FakeCuda(wrong_elems=3), expect_fail=False, launch=True)
    assert rc == 1 and "997/1000" in out


def test_old_driver_is_reported():
    rc, out = run(VECADD, FakeCuda(load_rc=222), expect_fail=False, launch=True)
    assert rc == 1 and "222 (CUDA_ERROR_UNSUPPORTED_PTX_VERSION)" in out and "ptxas error" in out


@pytest.mark.parametrize("load_rc,want", [(218, 0), (0, 1)])
def test_expect_fail(load_rc, want):
    rc, out = run(BAD, FakeCuda(load_rc=load_rc), expect_fail=True, launch=False)
    assert rc == want


def test_inputs_are_exact_in_float32():
    a, b = jit_probe.vecadd_inputs()
    assert all(jit_probe.f32(x) == x for x in a + b)
    assert all(jit_probe.f32(x + y) == x + y for x, y in zip(a, b))

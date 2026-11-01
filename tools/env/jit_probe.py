#!/usr/bin/env python3
"""Check that the CUDA driver can JIT-compile a PTX file, and optionally run the vector-add kernel.

    python3 tools/env/jit_probe.py tests/corpus/base/app.vecadd/kernel.ptx --launch-vecadd
    python3 tools/env/jit_probe.py docs/examples/cuda/bad.ptx --expect-fail

The script talks to libcuda.so directly through ctypes (no CUDA toolkit or Python CUDA package needed). It
creates a context on device 0 and hands the PTX text to cuModuleLoadDataEx, the same path the corpus runner
uses. It prints the driver version, the device, the result code and both JIT logs.

Exit code 0 means the outcome was the expected one: the module loaded (or, with --expect-fail, it was rejected)
and, with --launch-vecadd, every output element matched. CUDA_ERROR_UNSUPPORTED_PTX_VERSION (222) means the
driver is too old for the PTX version in the file.

--launch-vecadd expects the signature of the corpus entry app.vecadd: (const float *a, const float *b,
float *c, int n). It launches 4 blocks of 256 threads on n = 1000 elements and checks c = a + b exactly.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import re
import struct
import sys
from pathlib import Path

CU_JIT_INFO_LOG_BUFFER = 3
CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES = 4
CU_JIT_ERROR_LOG_BUFFER = 5
CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES = 6
CU_JIT_LOG_VERBOSE = 12
ATTR_CC_MAJOR, ATTR_CC_MINOR = 75, 76
LOG_BYTES = 1 << 16
N = 1000


def ptx_header(text: str) -> dict:
    """The .version and .target lines and the first .entry name of a PTX file."""
    def first(pattern: str) -> str | None:
        m = re.search(pattern, text, re.M)
        return m.group(1) if m else None
    return {"version": first(r"^\s*\.version\s+(\S+)"), "target": first(r"^\s*\.target\s+([^\s/]+)"),
            "entry": first(r"\.entry\s+([A-Za-z_$][\w$]*)\s*\(")}


def vecadd_inputs(n: int = N) -> tuple[list[float], list[float]]:
    """Inputs that are exactly representable, so c = a + b has one exact float32 answer."""
    return [0.5 * i - 100.0 for i in range(n)], [1000.0 - 0.25 * i for i in range(n)]


def f32(x: float) -> float:
    return struct.unpack("<f", struct.pack("<f", x))[0]


class Driver:
    """Thin wrapper over the few libcuda entry points the probe needs. Every call returns a CUresult."""

    def __init__(self, lib=None):
        self.lib = lib if lib is not None else ctypes.CDLL("libcuda.so.1")

    def name(self, rc: int) -> str:
        s = ctypes.c_char_p()
        if self.lib.cuGetErrorName(rc, ctypes.byref(s)) != 0 or not s.value:
            return "UNKNOWN"
        return s.value.decode()


def check(drv: Driver, rc: int, what: str) -> None:
    if rc != 0:
        raise RuntimeError(f"{what}: {rc} ({drv.name(rc)})")


def probe(ptx_path: Path, expect_fail: bool, launch: bool, drv: Driver | None = None, out=sys.stdout) -> int:
    text = ptx_path.read_text()
    head = ptx_header(text)
    print(f"ptx: {ptx_path}  version {head['version']}  target {head['target']}  entry {head['entry']}  "
          f"sha256 {hashlib.sha256(text.encode()).hexdigest()}", file=out)
    drv = drv or Driver()
    lib = drv.lib
    check(drv, lib.cuInit(0), "cuInit")
    ver = ctypes.c_int()
    check(drv, lib.cuDriverGetVersion(ctypes.byref(ver)), "cuDriverGetVersion")
    dev = ctypes.c_int()
    check(drv, lib.cuDeviceGet(ctypes.byref(dev), 0), "cuDeviceGet")
    name = ctypes.create_string_buffer(256)
    check(drv, lib.cuDeviceGetName(name, 256, dev), "cuDeviceGetName")
    major, minor = ctypes.c_int(), ctypes.c_int()
    check(drv, lib.cuDeviceGetAttribute(ctypes.byref(major), ATTR_CC_MAJOR, dev), "cuDeviceGetAttribute")
    check(drv, lib.cuDeviceGetAttribute(ctypes.byref(minor), ATTR_CC_MINOR, dev), "cuDeviceGetAttribute")
    print(f"driver api version: {ver.value // 1000}.{ver.value % 1000 // 10}  ({ver.value})", file=out)
    print(f"device 0: {name.value.decode()}  compute capability {major.value}.{minor.value}", file=out)
    ctx = ctypes.c_void_p()
    check(drv, lib.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev), "cuCtxCreate")

    info, err = ctypes.create_string_buffer(LOG_BYTES), ctypes.create_string_buffer(LOG_BYTES)
    opts = (ctypes.c_int * 5)(CU_JIT_INFO_LOG_BUFFER, CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES, CU_JIT_ERROR_LOG_BUFFER,
                              CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES, CU_JIT_LOG_VERBOSE)
    vals = (ctypes.c_void_p * 5)(ctypes.cast(info, ctypes.c_void_p), LOG_BYTES, ctypes.cast(err, ctypes.c_void_p),
                                 LOG_BYTES, 1)
    mod = ctypes.c_void_p()
    rc = lib.cuModuleLoadDataEx(ctypes.byref(mod), ctypes.c_char_p(text.encode() + b"\0"), 5, opts, vals)
    print(f"cuModuleLoadDataEx: {rc} ({drv.name(rc)})", file=out)
    print("jit info log:\n" + (info.value.decode(errors="replace").rstrip() or "(empty)"), file=out)
    print("jit error log:\n" + (err.value.decode(errors="replace").rstrip() or "(empty)"), file=out)

    if expect_fail:
        ok = rc != 0
        print(f"result: {'ok, rejected as expected' if ok else 'UNEXPECTED, the module loaded'}", file=out)
        return 0 if ok else 1
    if rc != 0:
        print("result: FAILED, the driver did not load the module", file=out)
        return 1
    if launch:
        mism = launch_vecadd(drv, mod, head["entry"])
        print(f"launch: {N - mism}/{N} elements match", file=out)
        if mism:
            print("result: FAILED, wrong vector-add output", file=out)
            return 1
    print("result: ok", file=out)
    return 0


def launch_vecadd(drv: Driver, mod: ctypes.c_void_p, entry: str | None) -> int:
    """Run the vector-add kernel once; return the number of wrong elements."""
    lib = drv.lib
    fn = ctypes.c_void_p()
    check(drv, lib.cuModuleGetFunction(ctypes.byref(fn), mod, (entry or "").encode()), "cuModuleGetFunction")
    a, b = vecadd_inputs()
    nbytes = 4 * N
    host = {k: (ctypes.c_float * N)(*v) for k, v in (("a", a), ("b", b), ("c", [0.0] * N))}
    dptr = {k: ctypes.c_uint64() for k in host}
    for k in dptr:
        check(drv, lib.cuMemAlloc_v2(ctypes.byref(dptr[k]), ctypes.c_size_t(nbytes)), "cuMemAlloc")
    for k in ("a", "b"):
        check(drv, lib.cuMemcpyHtoD_v2(dptr[k], host[k], ctypes.c_size_t(nbytes)), "cuMemcpyHtoD")
    check(drv, lib.cuMemsetD8_v2(dptr["c"], 0, ctypes.c_size_t(nbytes)), "cuMemsetD8")
    n = ctypes.c_int(N)
    args = (ctypes.c_void_p * 4)(*[ctypes.cast(ctypes.byref(x), ctypes.c_void_p) for x in
                                   (dptr["a"], dptr["b"], dptr["c"], n)])
    check(drv, lib.cuLaunchKernel(fn, 4, 1, 1, 256, 1, 1, 0, None, args, None), "cuLaunchKernel")
    check(drv, lib.cuCtxSynchronize(), "cuCtxSynchronize")
    check(drv, lib.cuMemcpyDtoH_v2(host["c"], dptr["c"], ctypes.c_size_t(nbytes)), "cuMemcpyDtoH")
    for k in dptr:
        lib.cuMemFree_v2(dptr[k])
    return sum(1 for i in range(N) if host["c"][i] != f32(f32(a[i]) + f32(b[i])))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ptx", type=Path)
    ap.add_argument("--expect-fail", action="store_true", help="success means the driver rejects the file")
    ap.add_argument("--launch-vecadd", action="store_true", help="also run the kernel as app.vecadd and check it")
    args = ap.parse_args(argv)
    try:
        return probe(args.ptx, args.expect_fail, args.launch_vecadd)
    except (OSError, RuntimeError) as e:
        print(f"result: FAILED, {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())

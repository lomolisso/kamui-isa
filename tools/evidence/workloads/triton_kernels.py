#!/usr/bin/env python3
"""Two Triton kernels for the instruction histograms, written for this project.

    python3 triton_kernels.py matmul     # C = A @ B, 2048 x 2048 x 2048, float16 in, float32 accumulate
    python3 triton_kernels.py softmax    # row softmax of a 4096 x 4096 float32 matrix, one program per row

Block sizes are fixed (no autotuning) so the compiled kernel is the same every run. On Hopper, Triton lowers
tl.dot to wgmma. Each kernel runs twice; the histogram tool counts the first launch.
"""
import sys

import torch
import triton
import triton.language as tl


@triton.jit
def kamui_matmul(a, b, c, M, N, K, sam, sak, sbk, sbn, scm, scn,
                 BM: tl.constexpr, BN: tl.constexpr, BK: tl.constexpr):
    pid_m = tl.program_id(0)
    pid_n = tl.program_id(1)
    rm = pid_m * BM + tl.arange(0, BM)
    rn = pid_n * BN + tl.arange(0, BN)
    rk = tl.arange(0, BK)
    pa = a + rm[:, None] * sam + rk[None, :] * sak
    pb = b + rk[:, None] * sbk + rn[None, :] * sbn
    acc = tl.zeros((BM, BN), dtype=tl.float32)
    for _ in range(0, K, BK):
        acc += tl.dot(tl.load(pa), tl.load(pb))
        pa += BK * sak
        pb += BK * sbk
    tl.store(c + rm[:, None] * scm + rn[None, :] * scn, acc)


@triton.jit
def kamui_softmax(x, y, stride, n, BLOCK: tl.constexpr):
    row = tl.program_id(0)
    cols = tl.arange(0, BLOCK)
    v = tl.load(x + row * stride + cols, mask=cols < n, other=-float("inf"))
    v = v - tl.max(v, axis=0)
    e = tl.exp(v)
    tl.store(y + row * stride + cols, e / tl.sum(e, axis=0), mask=cols < n)


def main() -> int:
    which = sys.argv[1] if len(sys.argv) > 1 else ""
    torch.manual_seed(0)
    if which == "matmul":
        n = 2048
        a = torch.randn(n, n, device="cuda", dtype=torch.float16)
        b = torch.randn(n, n, device="cuda", dtype=torch.float16)
        c = torch.empty(n, n, device="cuda", dtype=torch.float32)
        for _ in range(2):
            kamui_matmul[(n // 128, n // 128)](a, b, c, n, n, n, a.stride(0), a.stride(1), b.stride(0), b.stride(1),
                                               c.stride(0), c.stride(1), BM=128, BN=128, BK=64,
                                               num_warps=8, num_stages=3)
        torch.cuda.synchronize()
        err = (c - (a.float() @ b.float())).abs().max().item()
        print(f"matmul: max abs error vs torch {err:.4f}")
    elif which == "softmax":
        x = torch.randn(4096, 4096, device="cuda", dtype=torch.float32)
        y = torch.empty_like(x)
        for _ in range(2):
            kamui_softmax[(4096,)](x, y, x.stride(0), 4096, BLOCK=4096, num_warps=16)
        torch.cuda.synchronize()
        print(f"softmax: max abs error vs torch {(y - torch.softmax(x, 1)).abs().max().item():.2e}")
    else:
        print(__doc__)
        return 1
    print(f"triton {triton.__version__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

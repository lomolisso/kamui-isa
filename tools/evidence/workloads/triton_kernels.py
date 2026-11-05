#!/usr/bin/env python3
"""Triton kernels for the instruction histograms, written for this project.

    python3 triton_kernels.py matmul     # C = A @ B, 2048 x 2048 x 2048, float16 in, float32 accumulate
    python3 triton_kernels.py softmax    # row softmax of a 4096 x 4096 float32 matrix, one program per row
    python3 triton_kernels.py splitk     # C = A @ B with K split over 8 programs, partial sums added atomically
    python3 triton_kernels.py queue      # persistent programs take row blocks from an atomic counter
    python3 triton_kernels.py attention  # fused attention forward, online softmax, 1 x 16 x 2048 x 64, causal

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


@triton.jit
def kamui_splitk(a, b, c, M, N, K, sam, sak, sbk, sbn, scm, scn,
                 BM: tl.constexpr, BN: tl.constexpr, BK: tl.constexpr, SPLIT: tl.constexpr):
    pid_m = tl.program_id(0)
    pid_n = tl.program_id(1)
    pid_k = tl.program_id(2)
    rm = pid_m * BM + tl.arange(0, BM)
    rn = pid_n * BN + tl.arange(0, BN)
    rk = pid_k * (K // SPLIT) + tl.arange(0, BK)
    pa = a + rm[:, None] * sam + rk[None, :] * sak
    pb = b + rk[:, None] * sbk + rn[None, :] * sbn
    acc = tl.zeros((BM, BN), dtype=tl.float32)
    for _ in range(0, K // SPLIT, BK):
        acc += tl.dot(tl.load(pa), tl.load(pb))
        pa += BK * sak
        pb += BK * sbk
    tl.atomic_add(c + rm[:, None] * scm + rn[None, :] * scn, acc, sem="relaxed", scope="gpu")


@triton.jit
def kamui_queue(x, y, counter, done, rows, n, BR: tl.constexpr, BLOCK: tl.constexpr):
    # Each program loops: take the next block of rows from the counter, sum them, publish with release.
    cols = tl.arange(0, BLOCK)
    blk = tl.atomic_add(counter, 1, sem="acq_rel", scope="gpu")
    while blk * BR < rows:
        for r in range(BR):
            row = blk * BR + r
            v = tl.load(x + row * n + cols, mask=cols < n, other=0.0)
            tl.store(y + row, tl.sum(v, axis=0))
        tl.atomic_add(done, 1, sem="release", scope="gpu")
        blk = tl.atomic_add(counter, 1, sem="acq_rel", scope="gpu")


@triton.jit
def kamui_attention(q, k, v, o, S, sm_scale, BM: tl.constexpr, BN: tl.constexpr, D: tl.constexpr):
    # One program per (block of BM queries, head); q, k, v, o are [H, S, D] contiguous.
    start = tl.program_id(0) * BM
    head = tl.program_id(1)
    base = head * S * D
    rm = start + tl.arange(0, BM)
    rd = tl.arange(0, D)
    qb = tl.load(q + base + rm[:, None] * D + rd[None, :])
    m_i = tl.full((BM,), -float("inf"), tl.float32)
    l_i = tl.zeros((BM,), tl.float32)
    acc = tl.zeros((BM, D), tl.float32)
    for n0 in range(0, start + BM, BN):
        rn = n0 + tl.arange(0, BN)
        kb = tl.load(k + base + rn[:, None] * D + rd[None, :])
        s = tl.dot(qb, tl.trans(kb)) * sm_scale
        s = tl.where(rm[:, None] >= rn[None, :], s, -float("inf"))
        m_new = tl.maximum(m_i, tl.max(s, axis=1))
        p = tl.exp(s - m_new[:, None])
        alpha = tl.exp(m_i - m_new)
        l_i = l_i * alpha + tl.sum(p, axis=1)
        vb = tl.load(v + base + rn[:, None] * D + rd[None, :])
        acc = acc * alpha[:, None] + tl.dot(p.to(tl.float16), vb)
        m_i = m_new
    tl.store(o + base + rm[:, None] * D + rd[None, :], (acc / l_i[:, None]).to(tl.float16))


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
    elif which == "splitk":
        n = 2048
        a = torch.randn(n, n, device="cuda", dtype=torch.float16)
        b = torch.randn(n, n, device="cuda", dtype=torch.float16)
        for _ in range(2):
            c = torch.zeros(n, n, device="cuda", dtype=torch.float32)
            kamui_splitk[(n // 128, n // 128, 8)](a, b, c, n, n, n, a.stride(0), a.stride(1), b.stride(0),
                                                  b.stride(1), c.stride(0), c.stride(1), BM=128, BN=128, BK=64,
                                                  SPLIT=8, num_warps=8, num_stages=3)
        torch.cuda.synchronize()
        ref = a[:64].cpu().float() @ b.cpu().float()
        print(f"splitk: max abs error vs cpu (first 64 rows) {(c[:64].cpu() - ref).abs().max().item():.4f}")
    elif which == "queue":
        rows, n = 1 << 16, 1024
        x = torch.randn(rows, n, device="cuda", dtype=torch.float32)
        for _ in range(2):
            y = torch.empty(rows, device="cuda", dtype=torch.float32)
            counter = torch.zeros(1, device="cuda", dtype=torch.int32)
            done = torch.zeros(1, device="cuda", dtype=torch.int32)
            kamui_queue[(132 * 4,)](x, y, counter, done, rows, n, BR=8, BLOCK=1024, num_warps=4)
        torch.cuda.synchronize()
        err = (y.cpu() - x.cpu().sum(1)).abs().max().item()
        print(f"queue: {done.item()} blocks done (expect {rows // 8}), max abs error {err:.2e}")
    elif which == "attention":
        H, S, D = 16, 2048, 64
        q, k, v = (torch.randn(H, S, D, device="cuda", dtype=torch.float16) for _ in range(3))
        o = torch.empty_like(q)
        for _ in range(2):
            kamui_attention[(S // 128, H)](q, k, v, o, S, D ** -0.5, BM=128, BN=64, D=D, num_warps=8,
                                           num_stages=2)
        torch.cuda.synchronize()
        qc, kc, vc = (t[0, :256].cpu().float() for t in (q, k, v))
        s = (qc @ kc.T) * D ** -0.5
        s = s.masked_fill(torch.ones(256, 256).triu(1).bool(), float("-inf"))
        ref = torch.softmax(s, 1) @ vc
        print(f"attention: max abs error vs cpu (head 0, first 256 rows) {(o[0, :256].cpu().float() - ref).abs().max().item():.2e}")
    else:
        print(__doc__)
        return 1
    print(f"triton {triton.__version__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

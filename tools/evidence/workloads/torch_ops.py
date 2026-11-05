#!/usr/bin/env python3
"""PyTorch operations whose CUDA kernels are PyTorch's own (no cuBLAS or cuDNN), for the instruction histograms.

    python3 torch_ops.py <op>      # op: cumsum sort topk unique nonzero index_add scatter_add histc
                                   #     embedding_bwd layer_norm softmax

They are chosen for what they execute, not for speed:
  cumsum, sort, unique, nonzero   CUB device-wide scans and radix sort (decoupled look-back: flag polling with
                                  acquire/release and fences between thread blocks)
  topk                            radix select with block-wide counting
  index_add, scatter_add, histc   global and shared-memory atomics, with many collisions
  embedding_bwd                   sort plus segmented reduction (the dense embedding backward)
  layer_norm, softmax             block reductions with warp shuffles

Fixed sizes and seed 0. Each op runs twice; the histogram tool counts the first launch of each kernel. Results
are checked on the CPU, so no other GPU library runs.
"""
import sys

import torch

N = 1 << 24


def run(op: str) -> str:
    g = torch.Generator(device="cuda").manual_seed(0)
    dev = "cuda"
    if op == "cumsum":
        x = torch.randint(0, 3, (N,), device=dev, generator=g, dtype=torch.int64)
        y = torch.cumsum(x, 0)
        return f"last {y[-1].item()} == {x.sum().item()}"
    if op == "sort":
        x = torch.randn(N, device=dev, generator=g)
        y, _ = torch.sort(x)
        return f"sorted {bool((y[1:] >= y[:-1]).all().item())}"
    if op == "topk":
        x = torch.randn(64, 1 << 16, device=dev, generator=g)
        v, _ = torch.topk(x, 256, dim=1)
        return f"top {v[0, 0].item():.4f}"
    if op == "unique":
        x = torch.randint(0, 1 << 16, (N,), device=dev, generator=g)
        u = torch.unique(x)
        return f"unique {u.numel()}"
    if op == "nonzero":
        x = torch.randint(0, 4, (N,), device=dev, generator=g)
        nz = torch.nonzero(x == 0)
        return f"nonzero {nz.shape[0]}"
    if op == "index_add":
        idx = torch.randint(0, 1024, (N // 16,), device=dev, generator=g)
        src = torch.ones(N // 16, 16, device=dev)
        out = torch.zeros(1024, 16, device=dev).index_add_(0, idx, src)
        return f"sum {out.sum().item():.0f} == {N}"
    if op == "scatter_add":
        idx = torch.randint(0, 4096, (N,), device=dev, generator=g)
        out = torch.zeros(4096, device=dev).scatter_add_(0, idx, torch.ones(N, device=dev))
        return f"sum {out.sum().item():.0f} == {N}"
    if op == "histc":
        x = torch.rand(N, device=dev, generator=g)
        h = torch.histc(x, bins=256, min=0.0, max=1.0)
        return f"sum {h.sum().item():.0f} == {N}"
    if op == "embedding_bwd":
        emb = torch.nn.Embedding(50000, 256, device=dev)
        idx = torch.randint(0, 50000, (8192, 32), device=dev, generator=g)
        emb(idx).sum().backward()
        return f"grad sum {emb.weight.grad.sum().item():.0f}"
    if op == "layer_norm":
        x = torch.randn(8192, 4096, device=dev, generator=g)
        y = torch.nn.functional.layer_norm(x, (4096,))
        return f"mean {y.mean().item():.2e}"
    if op == "softmax":
        x = torch.randn(8192, 4096, device=dev, generator=g)
        y = torch.softmax(x, dim=1)
        return f"row sum {y[0].sum().item():.4f}"
    raise SystemExit(__doc__)


def main() -> int:
    op = sys.argv[1] if len(sys.argv) > 1 else ""
    for _ in range(2):
        msg = run(op)
    torch.cuda.synchronize()
    print(f"{op}: {msg} (torch {torch.__version__})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""PyTorch operations that run NVIDIA library kernels (cuBLAS, cuBLASLt, cuDNN), for instruction counts only.

    python3 vendor_ops.py <op>     # op: matmul_bf16 matmul_fp8 sdpa_cudnn conv_bf16

  matmul_bf16   torch.matmul, 4096 x 4096 x 4096 bfloat16 (cuBLAS / cuBLASLt Hopper GEMM kernels)
  matmul_fp8    torch._scaled_mm, 4096^3 float8_e4m3 with per-tensor scales (cuBLASLt FP8 GEMM)
  sdpa_cudnn    scaled_dot_product_attention with the cuDNN backend, 1 x 16 x 2048 x 128 bfloat16, causal
  conv_bf16     a 3x3 convolution, batch 32, 256 -> 256 channels, 56 x 56, bfloat16, channels-last (cuDNN)

These kernels are NVIDIA's, not open source: jobs/nvbit-hist.sh records only aggregate counts of them, and their
results are not committed to this repository. Fixed sizes, seed 0; each op runs twice and the histogram tool counts
the first launch of each kernel.
"""
import sys

import torch


def run(op: str) -> str:
    torch.manual_seed(0)
    dev = "cuda"
    if op == "matmul_bf16":
        a, b = (torch.randn(4096, 4096, device=dev, dtype=torch.bfloat16) for _ in range(2))
        return f"sum {torch.matmul(a, b).float().abs().sum().item():.3e}"
    if op == "matmul_fp8":
        a = torch.randn(4096, 4096, device=dev).to(torch.float8_e4m3fn)
        b = torch.randn(4096, 4096, device=dev).to(torch.float8_e4m3fn).t()
        one = torch.ones((), device=dev)
        c = torch._scaled_mm(a, b, scale_a=one, scale_b=one, out_dtype=torch.bfloat16)
        return f"sum {c.float().abs().sum().item():.3e}"
    if op == "sdpa_cudnn":
        from torch.nn.attention import SDPBackend, sdpa_kernel
        q, k, v = (torch.randn(1, 16, 2048, 128, device=dev, dtype=torch.bfloat16) for _ in range(3))
        with sdpa_kernel(SDPBackend.CUDNN_ATTENTION):
            o = torch.nn.functional.scaled_dot_product_attention(q, k, v, is_causal=True)
        return f"sum {o.float().abs().sum().item():.3e}"
    if op == "conv_bf16":
        x = torch.randn(32, 256, 56, 56, device=dev, dtype=torch.bfloat16).to(memory_format=torch.channels_last)
        conv = torch.nn.Conv2d(256, 256, 3, padding=1, bias=False, device=dev, dtype=torch.bfloat16)
        conv = conv.to(memory_format=torch.channels_last)
        with torch.no_grad():
            return f"sum {conv(x).float().abs().sum().item():.3e}"
    raise SystemExit(__doc__)


def main() -> int:
    op = sys.argv[1] if len(sys.argv) > 1 else ""
    for _ in range(2):
        msg = run(op)
    torch.cuda.synchronize()
    print(f"{op}: {msg} (torch {torch.__version__}, cuDNN {torch.backends.cudnn.version()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

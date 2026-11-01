#!/usr/bin/env python3
"""Attention forward pass for the instruction histograms: FlashInfer's Hopper prefill or flash-attn 2.

    python3 attention.py flashinfer     # flashinfer.single_prefill_with_kv_cache(backend="fa3"): wgmma + TMA
    python3 attention.py fa2            # flash_attn.flash_attn_func: Ampere-style mma.sync + cp.async

Fixed shape: batch 1, 16 heads, sequence 2048, head dimension 128, bfloat16, causal, seed 0. The kernel runs
twice; the histogram tool counts the first launch of each kernel.
"""
import sys

import torch

B, H, S, D = 1, 16, 2048, 128


def main() -> int:
    impl = sys.argv[1] if len(sys.argv) > 1 else ""
    torch.manual_seed(0)
    q, k, v = (torch.randn(S, H, D, device="cuda", dtype=torch.bfloat16) for _ in range(3))
    for _ in range(2):
        if impl == "flashinfer":
            import flashinfer
            o = flashinfer.single_prefill_with_kv_cache(q, k, v, causal=True, backend="fa3")
        elif impl == "fa2":
            import flash_attn
            o = flash_attn.flash_attn_func(q[None], k[None], v[None], causal=True)[0]
        else:
            print(__doc__)
            return 1
    torch.cuda.synchronize()
    print(f"{impl}: output {tuple(o.shape)} {o.dtype}, checksum {o.float().abs().sum().item():.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

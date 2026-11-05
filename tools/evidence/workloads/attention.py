#!/usr/bin/env python3
"""Attention kernels for the instruction histograms: FlashInfer and flash-attn 2.

    python3 attention.py flashinfer     # flashinfer.single_prefill_with_kv_cache(backend="fa3"): wgmma + TMA
    python3 attention.py fa2            # flash_attn.flash_attn_func: Ampere-style mma.sync + cp.async
    python3 attention.py fa2_bwd        # flash-attn 2 forward and backward (dq accumulated with atomics)
    python3 attention.py fi_decode      # flashinfer.single_decode_with_kv_cache: one query per head, split KV
    python3 attention.py fi_paged       # FlashInfer batch prefill on a paged KV cache (page 16), backend fa3

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
        elif impl == "fa2_bwd":
            import flash_attn
            qg, kg, vg = (t[None].clone().requires_grad_() for t in (q, k, v))
            o = flash_attn.flash_attn_func(qg, kg, vg, causal=True)[0]
            o.float().sum().backward()
            o = qg.grad[0]
        elif impl == "fi_decode":
            import flashinfer
            o = flashinfer.single_decode_with_kv_cache(q[0], k, v)
        elif impl == "fi_paged":
            import flashinfer
            page, batch = 16, 4
            pages = S // page                       # pages per request; every request has the full length S
            kv = torch.randn(batch * pages, 2, page, H, D, device="cuda", dtype=torch.bfloat16)
            qb = torch.randn(batch * 256, H, D, device="cuda", dtype=torch.bfloat16)   # 256 new queries each
            qo_indptr = torch.arange(0, batch + 1, device="cuda", dtype=torch.int32) * 256
            kv_indptr = torch.arange(0, batch + 1, device="cuda", dtype=torch.int32) * pages
            kv_indices = torch.arange(0, batch * pages, device="cuda", dtype=torch.int32)
            last = torch.full((batch,), page, device="cuda", dtype=torch.int32)
            ws = torch.empty(256 << 20, device="cuda", dtype=torch.uint8)
            w = flashinfer.BatchPrefillWithPagedKVCacheWrapper(ws, "NHD", backend="fa3")
            w.plan(qo_indptr, kv_indptr, kv_indices, last, H, H, D, page, causal=True)
            o = w.run(qb, kv)
        else:
            print(__doc__)
            return 1
    torch.cuda.synchronize()
    print(f"{impl}: output {tuple(o.shape)} {o.dtype}, checksum {o.float().abs().sum().item():.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

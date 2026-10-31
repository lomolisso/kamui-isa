# cuobjdump

## What it is

`cuobjdump` lists and dumps the GPU parts of CUDA binaries: cubins, fat
binaries embedded in host objects and executables, and the PTX that some of
them carry. For kamui-isa it is the quickest way to get **SASS** (the H100's
real machine code) and **resource usage** for our own micro-kernels.

SASS is design evidence only. It tells us whether the hardware needed one
instruction or a sequence for a PTX construct, how modifiers such as scope
were encoded, and which hidden mechanisms (convergence barriers, uniform
datapath, warp aggregation) sit behind the PTX. SASS is never translated and
never a compilation input: Kamui's input is PTX text.

Licensing: SASS of **our own** kernels may be committed under `evidence/`.
SASS of NVIDIA library kernels (cuBLAS, cuDNN, and so on) must not be
committed.

## Where it runs

Dev container. (Also present on the H100 job image; use it there only to
inspect binaries that exist only on the job image, such as a Triton cache.)

## Version pinned

```
cuobjdump: NVIDIA (R) fat binary listing tool
Cuda compilation tools, release 12.8, V12.8.90
Build cuda_12.8.r12.8/compiler.35538042_0
```

## Commands we use

```bash
cuobjdump -sass k.cubin            # SASS with encodings, one function after another
cuobjdump -sass -fun toy k.cubin   # one function by name
cuobjdump -res-usage k.cubin       # registers, shared, local, constant bank sizes per function
cuobjdump -elf k.cubin             # ELF sections and symbols (shared memory layout, .nv.info)
cuobjdump -lelf -lptx app.o        # list cubins and PTX embedded in a host object/executable
cuobjdump -xelf all app            # extract embedded cubins to files (then use nvdisasm)
cuobjdump -arch sm_90a -sass app   # only the sm_90a cubin of a multi-arch fatbin
```

Options per `cuobjdump --help` (12.8): `-sass`, `-ptx`, `-elf`, `-symbols`,
`-res-usage`, `-lelf`, `-lptx`, `-ltext`, `-xelf`, `-xptx`, `-xtext`,
`-fun <name>`, `-findex`, `-arch`, `-all` (all fatbin sections),
`-sort`.

## Input formats

Cubins (from `ptxas`), host objects and executables with embedded fatbins
(from `nvcc` or `clang -x cuda -c`), fatbin files.

## Output formats

`-sass` prints a header and then each instruction as
`/*offset*/  [@pred] OPCODE.MODIFIERS operands ;  /* encoding */`. Hopper
instructions are 128 bits, printed as two 64-bit hex words on two lines (the
second word carries mostly scheduling control: stall counts, yield, read and
write scoreboard barriers, reuse flags). Offsets step by 0x10.

`-res-usage` prints, per function,
`REG:14 STACK:0 SHARED:1028 LOCAL:0 CONSTANT[0]:552 TEXTURE:0 SURFACE:0 SAMPLER:0`.
`SHARED` includes the 1 KB per-CTA reserved region on sm_90 (1024 + our 4
bytes); `CONSTANT[0]` is the size of constant bank 0 (driver data plus kernel
parameters, which start at offset 0x210 on sm_90).

## Worked example

Input: `toy.cubin` built from [toy.cu](../examples/cuda/toy.cu) as shown in
[clang-cuda.md](clang-cuda.md) and [ptxas.md](ptxas.md)
(`ptxas -arch=sm_90a -v -o toy.cubin toy.ptx`, in `build/examples/cuda` in the
dev container, 2026-10-29). `cuobjdump -sass toy.cubin`, encodings removed,
annotated:

```
	code for sm_90a
		Function : toy
	.headerflags	@"EF_CUDA_TEXMODE_UNIFIED EF_CUDA_64BIT_ADDRESS EF_CUDA_ACCELERATORS EF_CUDA_SM90 EF_CUDA_VIRTUAL_SM(EF_CUDA_SM90)"
/*0000*/        LDC R1, c[0x0][0x28] ;              // stack pointer from constant bank 0
/*0010*/        S2R R8, SR_TID.X ;                  // %tid.x (per-thread special register, slow path)
/*0020*/        S2UR UR8, SR_CTAID.X ;              // %ctaid.x into a UNIFORM register (same for the whole warp)
/*0030*/        ULDC.64 UR6, c[0x0][0x208] ;        // global memory descriptor used by desc[UR6] below
/*0040*/        LDC R11, c[0x0][RZ] ;               // %ntid.x lives at c[0x0][0x0]
/*0050*/        LDC.64 R2, c[0x0][0x210] ;          // kernel param 0 (in) at c[0x0][0x210]
/*0060*/        ISETP.NE.AND P0, PT, R8, RZ, PT ;   // P0 = (tid != 0)
/*0070*/        IMAD R5, R11, UR8, R8 ;             // blockIdx.x*blockDim.x+tid, mixing R and UR operands
/*0080*/        IMAD.WIDE.U32 R2, R5, 0x4, R2 ;     // 64-bit address = in + 4*i
/*0090*/   @!P0 S2R R7, SR_CgaCtaId ;               // CTA id inside the cluster (CGA = cooperative grid array)
/*00a0*/   @!P0 MOV R0, 0x400 ;                     // 1 KB reserved shared memory: our variable is at 0x400
/*00b0*/   @!P0 LEA R0, R7, R0, 0x18 ;              // shared address = (CgaCtaId << 24) + 0x400
/*00c0*/   @!P0 STS [R0], RZ ;                      // cta_sum = 0, predicated instead of branching
/*00d0*/        BAR.SYNC.DEFER_BLOCKING 0x0 ;       // __syncthreads(): bar.sync 0
/*00e0*/        LDG.E R2, desc[UR6][R2.64] ;        // global load through the memory descriptor
/*00f0*/        LOP3.LUT P1, RZ, R8, 0x1f, RZ, 0xc0, !PT ;  // P1 = (tid & 31) != 0
/*0100*/        BSSY B0, 0x2e0 ;                    // CONVERGENCE BARRIER: open B0, reconverge at 0x2d0/0x2e0
/*0110*/        VOTE.ANY R9, PT, PT ;               // activemask.b32 (inline asm) == VOTE.ANY of PT
/*0120*/        SHFL.BFLY PT, R5, R2, 0x10, 0x1f ;  // shfl.sync.bfly 16, clamp 31; full mask so no WARPSYNC
/*0130*/        IMAD.IADD R5, R2, 0x1, R5 ;
   ...                                              // 4 more SHFL.BFLY (8, 4, 2, 1) with adds
/*01b0*/    @P1 BRA 0x2d0 ;                         // divergent branch: lanes != 0 jump to the BSYNC
/*01c0*/        S2R R0, SR_LANEID ;                 // ---- warp-aggregated shared atomic, inserted by ptxas:
/*01e0*/        S2UR UR5, SR_CgaCtaId ;
/*01f0*/        VOTEU.ANY UR4, UPT, PT ;            //   UR4 = mask of active lanes (uniform)
/*0210*/        REDUX.SUM UR9, R6 ;                 //   sum of the values across active lanes (redux into UR)
/*0220*/        UFLO.U32 UR4, UR4 ;                 //   leader = lowest active lane
/*0240*/        ISETP.EQ.U32.AND P1, PT, R0, UR4, PT ;  //   P1 = (laneid == leader)
/*0270*/        ULEA UR4, UR5, UR4, 0x18 ;          //   shared address of cta_sum in a uniform register
/*02b0*/    @P1 ATOMS.ADD RZ, [UR4], R0 ;           //   ONE shared atomic per warp (atom.shared.add.u32)
/*02c0*/        STG.E desc[UR6][R2.64], R9 ;        // mask_out[...] = am
/*02d0*/        BSYNC B0 ;                          // CONVERGENCE: wait until all lanes of B0 arrive
/*02e0*/        BAR.SYNC.DEFER_BLOCKING 0x0 ;
/*02f0*/    @P0 EXIT ;                              // threads with tid != 0 exit early
/*0340*/        LDS R5, [UR4] ;                     // ld.shared
/*0350*/        REDG.E.ADD.STRONG.GPU desc[UR6][R2.64], R5 ;  // atom.global.add with unused result -> RED; scope .gpu = STRONG.GPU
/*0360*/        EXIT ;
/*0370*/        BRA 0x370;                          // padding self-loop, never reached
/*0380*/        NOP;                                // alignment padding to 128 bytes
```

Encoding example: `/*0120*/ SHFL.BFLY PT, R5, R2, 0x10, 0x1f ; /* 0x0e001f0002057f89 */`
followed by the second word `/* 0x004e6400000e0000 */`.

`cuobjdump -res-usage toy.cubin`:

```
 Function toy:
  REG:14 STACK:0 SHARED:1028 LOCAL:0 CONSTANT[0]:552 TEXTURE:0 SURFACE:0 SAMPLER:0
```

`cuobjdump -elf toy.cubin` shows the shared-memory layout behind the
`0x400` constant: `.nv.shared.reserved.0`, symbol
`.nv.reservedSmem.offset0` (size 4), and `.nv.shared.toy` of size 0x404.

A clang host+device object
(`clang++-20 -x cuda --cuda-gpu-arch=sm_90a -O2 --cuda-feature=+ptx87 --cuda-path=/usr/local/cuda -c -o toy.o $EX/toy.cu`).
The output names the object path, which was `out/toy.o` when this was recorded:

```
$ cuobjdump -lelf -lptx toy.o
ELF file    1: toy.1.sm_90a.cubin
cuobjdump info    : No PTX file found to extract from 'out/toy.o'. You may try with -all option.
```

## How to read Hopper SASS (cheat sheet)

NVIDIA does not document SASS semantics. The meanings below are our reading,
backed by experiments like the one above.

| Pattern | Meaning | Kamui relevance |
|---|---|---|
| `@P0`, `@!P0`, `PT`, `!PT` | Guard predicate; `PT` is the always-true predicate register, `RZ` the zero register | Predication in `Xkmsimt` |
| `R0..R254`, `RZ` | Per-thread 32-bit registers (255 usable) | Register-model decision |
| `UR0..UR62`, `URZ`, `UP0..`, `UPT` | Uniform (warp-wide scalar) registers and predicates; `S2UR`, `ULDC`, `UIADD3`, `ULEA`, `UMOV`, `UFLO`, `VOTEU` operate on them | Uniform-datapath decision |
| `BSSY Bn, target` / `BSYNC Bn` | Convergence barrier: lanes register at BSSY, wait at BSYNC. Volta+ mechanism behind independent thread scheduling | Convergence decision |
| `BREAK`, `BMOV`, `WARPSYNC mask`, `WARPSYNC.ALL` | Leave a convergence barrier; move barrier state; `__syncwarp`/`bar.warp.sync` and non-full `.sync` masks | Convergence decision, `Xkmwarp` |
| `BAR.SYNC.DEFER_BLOCKING 0x0`, `BAR.ARV`, `BAR.RED` | CTA named barriers (`bar.sync`, `bar.arrive`, `bar.red`) | `Xkmbar` |
| `UCGABAR_ARV`, `UCGABAR_WAIT` | `barrier.cluster.arrive` / `wait` (seen in `hopper.cu`) | `Xkmcluster` |
| `SHFL.{IDX,UP,DOWN,BFLY}`, `VOTE.{ANY,ALL,EQ}`, `VOTEU`, `MATCH`, `REDUX`, `ELECT` | Warp primitives. `activemask` = `VOTE.ANY R, PT, PT` | `Xkmwarp` |
| `LDG/STG`, `LDS/STS`, `LDL/STL`, `LD/ST` (generic), `LDC`/`ULDC` | Global, shared, local, generic, constant memory | Addressing decision (shared and local windows, generic pointers) |
| `.E` | 64-bit (extended) address | |
| `desc[URx][Ry.64]` | Access through a memory descriptor held in a uniform register pair | |
| `.STRONG.SM`, `.STRONG.GPU`, `.STRONG.SYS`, (no qualifier = weak) | Scope of a memory operation: PTX `.cta` -> `STRONG.SM`, `.gpu` -> `STRONG.GPU`, `.sys` -> `STRONG.SYS` | `Xkmscope`, scope-encoding decision |
| `ATOM`, `ATOMG`, `ATOMS`, `RED`, `REDG` | Generic, global, shared atomics; `RED*` when the result is unused | `Xkmscope` |
| `MEMBAR.SC.{CTA,GPU,SYS}`, `MEMBAR.ALL.{CTA,GPU,SYS}`, `ERRBAR`, `CGAERRBAR`, `CCTL.IVALL` | Fences; `.SC` for sequentially consistent, `.ALL` for release-style; `CCTL.IVALL` invalidates L1 (acquire side) | `Xkmscope` |
| `LDGSTS`, `LDGDEPBAR`, `DEPBAR.LE SB0, n` | `cp.async`, `cp.async.commit_group`, `cp.async.wait_group n` | `Xkmasync` |
| `SYNCS.EXCH.64`, `SYNCS.ARRIVE.TRANS64.*`, `SYNCS.PHASECHK.TRANS64` | `mbarrier.init`, `mbarrier.arrive`, `mbarrier.test_wait` | `Xkmmbar` |
| `UTMALDG`, `UTMASTG`, `UBLKCP`, `UTMAPF` | TMA tensor and bulk copies (`cp.async.bulk[.tensor]`) | `Xkmasync` |
| `WARPGROUP.ARRIVE`, `HGMMA.64xNx16.F32 ... gdesc[URx] ... gsb0`, `WARPGROUP.DEPBAR.LE gsb0, n` | `wgmma.fence`, `wgmma.mma_async`, `wgmma.wait_group` | `Xkmmma` |
| `HMMA.16816.F32`, `LDSM`, `STSM` | `mma.sync`, `ldmatrix`, `stmatrix` | `Xkmmma` |
| `MUFU.{RCP,RSQ,EX2,LG2,SIN,COS,TANH}` | Special function unit (`.approx` math) | `Xkmmufu` |
| `S2R SR_*`, `CS2R`, `S2UR` | Special registers (`SR_TID.X`, `SR_LANEID`, `SR_LTMASK`, `SR_CgaCtaId`, `SR_CLOCKLO`) | `Xkmsimt` CSRs |
| `@!PT LDS RZ, [RZ]` | Never-executed placeholder (guard is false); appears before fences and `LDGSTS` | Exclude from histograms (`thread_execs_pred_on` = 0) |

Real fence and ordering sequences measured from
[atomics.cu](../examples/cuda/atomics.cu) and
[hopper.cu](../examples/cuda/hopper.cu) (dev container, ptxas 12.8.93):

| PTX | SASS sequence |
|---|---|
| `membar.cta` | `MEMBAR.SC.CTA` |
| `membar.gl` | `MEMBAR.SC.GPU ; ERRBAR ; CGAERRBAR ; CCTL.IVALL` |
| `membar.sys`, `fence.sc.sys` | `MEMBAR.SC.SYS ; ERRBAR ; CGAERRBAR ; CCTL.IVALL` |
| `fence.sc.cluster` | `MEMBAR.ALL.CTA ; MEMBAR.SC.GPU ; ERRBAR ; CGAERRBAR ; CCTL.IVALL` (cluster scope is implemented with a GPU-scope membar) |
| `ld.acquire.sys.global.u32` | `LDG.E.STRONG.SYS ; CCTL.IVALL` |
| `ld.relaxed.sys.global.u32` | `LDG.E.STRONG.SYS` |
| `st.release.sys.global.u32` | `MEMBAR.ALL.SYS ; ERRBAR ; CGAERRBAR ; STG.E.STRONG.SYS` (plus `@!PT LDS` placeholders) |
| `atom.global.add.u32` (no scope = `.gpu`) | `ATOMG.E.ADD.STRONG.GPU`, warp-aggregated when the address is warp-uniform (`VOTEU.ANY`, `FLO`, `POPC`, leader lane, `SHFL.IDX` to broadcast the old value, `SR_LTMASK` + `POPC` for each lane's offset) |
| `atom.cta.add.s32` (generic address) | `ATOM.E.ADD.S32.STRONG.SM` (also warp-aggregated) |
| `atom.global.cas.b32` | `ATOMG.E.CAS.STRONG.GPU` |
| `redux.sync.add.s32` | `REDUX.SUM.S32 URx, Ry` (result in a uniform register) |
| `mbarrier.init.shared.b64 [b], n` | uniform computation of `(0x100000 - n)` shifted, then `SYNCS.EXCH.64 URZ, [URx], URy` |
| `mbarrier.arrive.shared.b64` | `SYNCS.ARRIVE.TRANS64.A1T0 R2, [UR7], RZ` |
| `mbarrier.test_wait.shared.b64` | `SYNCS.PHASECHK.TRANS64 P0, [UR7], R3` |
| `cp.async.ca.shared.global [..],[..],4` | `LDGSTS.E [R5], desc[UR10][R2.64]` |
| `cp.async.commit_group` / `cp.async.wait_all` | `LDGDEPBAR` / `LDGDEPBAR ; DEPBAR.LE SB0, 0x0` |
| `barrier.cluster.arrive` / `wait` | runtime check of cluster size (`LDC c[0x0][0x140]`); if 1, `BAR.SYNC`; else `MEMBAR.ALL.CTA ; MEMBAR.ALL.GPU ; ERRBAR ; CGAERRBAR ; UCGABAR_ARV` then `UCGABAR_WAIT ; CCTL.IVALL` |
| `%cluster_ctarank` | `S2UR SR_CgaCtaId` |
| `wgmma.fence` | `WARPGROUP.ARRIVE` |
| `wgmma.commit_group` + `wait_group 0` with no MMA in between | ptxas inserts a dummy `HGMMA.64x8x16.F16 RZ, gdesc[URZ], RZ, !UPT, gsb0` then `WARPGROUP.DEPBAR.LE gsb0, 0x0` |
| `setmaxnreg.inc.sync.aligned.u32 232` in a kernel without known entry register count | dropped (ptxas info C7508), no SASS |

These rows are a first sample of the per-feature SASS dataset that the H100
evidence work builds systematically.

To reproduce: compile `hopper.cu` and `atomics.cu` with the canonical command
from [clang-cuda.md](clang-cuda.md), assemble with `ptxas -arch=sm_90a -v`,
and run `cuobjdump -sass` on the cubins.

## How kamui-isa uses it

- **SASS evidence**: `cuobjdump -sass` (or `nvdisasm`, see
  [nvdisasm.md](nvdisasm.md)) of every corpus cubin goes to
  `evidence/sass/<feature>.sass`; `-res-usage` feeds the resource columns of
  the dataset. Each catalog entry is annotated with: one SASS instruction or
  a sequence, how modifiers were encoded, which hidden mechanism appeared
  (uniform registers, BSSY/BSYNC, warp aggregation, ERRBAR/CCTL around
  fences).
- **Execution-model decisions**: evidence for convergence
  (BSSY/BSYNC/WARPSYNC), scope encoding (STRONG.SM/GPU/SYS, MEMBAR variants),
  shared-window addressing (`SR_CgaCtaId << 24` and the 0x400 reserved
  offset) and the uniform datapath (uniform registers everywhere).

## Limitations and gotchas

- NVIDIA does not document SASS semantics. The opcode list in the CUDA
  Binary Utilities manual gives one-line descriptions only. Interpretations in
  our notes are hypotheses backed by experiments; label them as such.
- `cuobjdump -sass` does not print branch-target labels; `nvdisasm` does
  (`` `(.L_x_0) ``). Prefer `nvdisasm` for control flow.
- The dev container's ptxas and the H100 driver JIT may produce different
  SASS for the same PTX if versions differ. SASS evidence always records the
  ptxas version.
- ptxas optimisations change what you see (warp-aggregated atomics, RED,
  dummy HGMMA). Write micro-kernels so that the feature under test survives
  (non-uniform addresses when you want per-lane atomics, results used).

## References

- NVIDIA, *CUDA Binary Utilities* (cuobjdump, nvdisasm, SASS opcode lists for
  Hopper): https://docs.nvidia.com/cuda/archive/12.8.1/cuda-binary-utilities/index.html
- `cuobjdump --help` in the dev container.

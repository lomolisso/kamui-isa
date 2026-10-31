# nvdisasm

## What it is

`nvdisasm` disassembles a cubin into SASS, like `cuobjdump -sass`, but with
more analysis: branch-target labels, control-flow graphs in Graphviz format,
register live ranges, source-line annotation, and **JSON output** (new enough
in 12.8 to rely on). It reads only cubins (ELF), not host executables; use
`cuobjdump -xelf` first to extract a cubin from a fat binary.

How to read the SASS itself (predicates, uniform registers, BSSY/BSYNC,
scopes, fence sequences) is explained in [cuobjdump.md](cuobjdump.md),
"How to read Hopper SASS". This page covers what is specific to `nvdisasm`.

## Where it runs

Dev container.

## Version pinned

```
nvdisasm: NVIDIA (R) CUDA disassembler
Cuda compilation tools, release 12.8, V12.8.90
Build cuda_12.8.r12.8/compiler.35538042_0
```

## Commands we use

```bash
nvdisasm -c k.cubin                    # code sections only, with branch labels
nvdisasm -c -hex k.cubin               # plus encodings
nvdisasm -json k.cubin > k.json        # machine-readable SASS for the evidence tooling
nvdisasm -bbcfg k.cubin > k.dot        # CFG with one node per basic block (Graphviz)
nvdisasm -cfg k.cubin > k.dot          # CFG with one node per hyperblock
dot -Tsvg k.dot -o k.svg               # render (graphviz, if installed)
nvdisasm -c -plr -lrm count k.cubin    # live register counts per instruction (GPR, PRED, UGPR)
nvdisasm -c -g k.cubin                 # source lines; needs .loc in the PTX and ptxas -lineinfo
nvdisasm -c -fun 3 k.cubin             # one function by symbol index
```

Options per `nvdisasm --help` (12.8): `-c` (`--print-code`), `-hex`,
`-json` (`--emit-json`), `-cfg`, `-bbcfg`, `-poff` (offsets in the CFG),
`-plr` and `-lrm {count,wide,narrow}` (live ranges), `-g`, `-gi`, `-gp`
(line info from `.debug_line`, with inlining, or from `.nv_debug_line_sass`),
`-ndf` (no dataflow), `-novliw`, `-raw`, `-sf` (separate functions), `-sort`,
`-fun`, `-b SM90a` (raw instruction binary input).

## Input formats

A cubin. `-b SM90a` accepts a raw instruction stream (for example from
`cuobjdump -xtext`).

## Output formats

Text: same instruction syntax as `cuobjdump`, plus ELF directives
(`.section`, `.global`, `.type`, `.size`, `.other`) and labels. Branch targets
are printed symbolically: `` BSSY B0, `(.L_x_0) `` and `` @P1 BRA `(.L_x_1) ``,
with `.L_x_1:` before the target instruction. This makes divergence regions
easy to see: a `BSSY Bn` opens a region whose reconvergence point is the
label it names; `BSYNC Bn` closes it.

JSON (`-json`), real excerpt for `toy.cubin`:

```json
[{"ELF":{"layout-id":4,"ei_osabi":51,"ei_abiversion":7},
  "SM":{"version":{"major":9,"minor":0}},
  "SchemaVersion":{"major":12,"minor":8,"revision":0},
  "Producer":"nvdisasm V12.8.90 Build cuda_12.8.r12.8/compiler.35538042_0","Description":""},
 [{"function-name":"toy","start":0,"length":1024,"other-attributes":[],
   "sass-instructions":[
     {"opcode":"LDC","operands":"R1,c[0x0][0x28]"},
     {"opcode":"S2R","operands":"R8,SR_TID.X"},
     {"predicate":"@!P0","opcode":"S2R","operands":"R7,SR_CgaCtaId"},
     {"opcode":"BSSY","operands":"B0,0x2e0","other-attributes":{"control-flow":"True"}},
     ...]}]]
```

Fields: `opcode` is the full opcode with modifiers (`ISETP.NE.AND`,
`REDG.E.ADD.STRONG.GPU`), `operands` is a comma-separated string,
`predicate` appears only for guarded instructions, and
`other-attributes.control-flow` marks branches and convergence instructions.
Offsets are implicit (index times 16 from `start`). **Use `-json` as the
input of the SASS evidence parser** instead of regex-parsing the text form;
split `opcode` on `.` to get the base opcode and the modifier list.

Graphviz (`-bbcfg`): one `Mrecord` node per basic block with the instructions
as the label, and edges `"toy":exit0:e -> ".L_x_1":entry:n` for taken
branches and `:s` for fall-through. For `toy.cubin` the CFG has five blocks:
entry (up to `@P1 BRA`), the leader-only block (the warp-aggregated `ATOMS`),
`.L_x_1` (`BSYNC B0` alone), `.L_x_0` (`BAR.SYNC` and `@P0 EXIT`), and the
final block with the global `REDG`.

Live ranges (`-plr -lrm count`), real excerpt: the trailing columns count live
general registers, predicates and uniform registers at each instruction:

```
        /*0020*/                   S2UR UR8, SR_CTAID.X ;                            // |   4   |        |   1    |
        /*0030*/                   ULDC.64 UR6, c[0x0][0x208] ;                      // |   4   |        |   3    |
        /*0060*/                   ISETP.NE.AND P0, PT, R8, RZ, PT ;                 // |   7   |   1    |   3    |
```

This is how we can measure register pressure per instruction (for example the
peak live registers inside a `wgmma` main loop) rather than only the
per-kernel total from `ptxas -v`.

## Worked example

Dev container, in `build/examples/cuda` as set up in
[clang-cuda.md](clang-cuda.md). The cubin comes from
`ptxas -arch=sm_90a -v -o toy.cubin toy.ptx` ([ptxas.md](ptxas.md)):

```
$ nvdisasm -c toy.cubin
...
        /*0100*/                   BSSY B0, `(.L_x_0) ;              // open convergence region B0
        /*0110*/                   VOTE.ANY R9, PT, PT ;              // activemask
        /*0120*/                   SHFL.BFLY PT, R5, R2, 0x10, 0x1f ;
        ...
        /*01b0*/               @P1 BRA `(.L_x_1) ;                    // lanes with tid%32 != 0 skip ahead
        /*01c0*/                   S2R R0, SR_LANEID ;
        ...
        /*02b0*/               @P1 ATOMS.ADD RZ, [UR4], R0 ;
        /*02c0*/                   STG.E desc[UR6][R2.64], R9 ;
.L_x_1:
        /*02d0*/                   BSYNC B0 ;                         // all lanes that entered B0 meet here
.L_x_0:
        /*02e0*/                   BAR.SYNC.DEFER_BLOCKING 0x0 ;
        /*02f0*/               @P0 EXIT ;
...
.L_x_2:
        /*0370*/                   BRA `(.L_x_2);                     // padding loop
```

`nvdisasm -c -g` on a cubin without line info prints no line annotations. To
get them, compile with `clang++-20 ... -gline-tables-only` (emits `.loc` in
the PTX) and assemble with `ptxas -lineinfo`.

## How kamui-isa uses it

- **SASS evidence**: `nvdisasm -json` of every corpus cubin is the input to
  the SASS evidence script (planned as `tools/evidence/sass.py`), which
  produces the per-feature SASS observations dataset (proposed columns:
  `feature`, `kernel`, `pc`, `opcode`, `base_opcode`, `modifiers`,
  `predicate`, `operands`, `is_control_flow`, `uses_uniform`,
  `in_feature_window`). The text form with labels goes to `evidence/sass/`
  for humans.
- **Convergence decision**: `-bbcfg` renders divergence and reconvergence
  (BSSY/BSYNC regions, WARPSYNC placement), which is evidence for choosing
  between IPDOM split/join and per-thread PCs with convergence barriers.
- **Register-model decision**: `-plr` live-register counts.

## Limitations and gotchas

- Only cubins. For a host binary: `cuobjdump -xelf all app` first.
- The JSON schema is versioned (`SchemaVersion 12.8.0`); pin the parser to it
  and fail loudly on a different version.
- Hyperblock CFGs (`-cfg`) merge blocks across predicated code; use `-bbcfg`
  for analysis.
- Dataflow analysis (on by default) can fail on unusual cubins; `-ndf`
  disables it (labels then may be missing).
- To isolate a feature inside a micro-kernel's SASS, bracket it in the CUDA
  source with markers that survive compilation. `asm volatile("// KAMUI_BEGIN");`
  is a PTX comment and disappears in SASS, so use a cheap, distinctive
  instruction instead, such as reading `%clock` (`S2R SR_CLOCKLO` / `CS2R`)
  before and after, and record the window in the descriptor.

## References

- NVIDIA, *CUDA Binary Utilities*, nvdisasm chapter:
  https://docs.nvidia.com/cuda/archive/12.8.1/cuda-binary-utilities/index.html
- `nvdisasm --help` in the dev container.

# riscv-opcodes

## What it is

riscv-opcodes is the official machine-readable table of RISC-V instruction encodings and CSR
addresses. It comes with a Python generator (`riscv_opcodes`) that checks the table for mistakes
(overlapping encodings, bits assigned twice, unknown fields) and emits decoder tables for C,
SystemVerilog, Chisel, SpinalHDL, Rust, Go and LaTeX.

The Kamui `Xkm` encodings are written in this format under `encodings/`. The generator is Kamui's
overlap checker and the source of its decoder tables. The source is in
[`deps/riscv-opcodes`](../../deps/riscv-opcodes) (read-only).

## Where it runs

In the dev container (see [devcontainer.md](devcontainer.md)). It needs only Python 3.9+ and the
standard library (matplotlib only for the optional SVG output).

## Version pinned

- `deps/riscv-opcodes` at commit `f24ac23` (2026-10-14).
- Python 3.12.3 in the container. No `pip install` is needed: run the module from the source tree
  with `PYTHONPATH=src python3 -m riscv_opcodes`.

## Commands we use

The generator only reads extension files from its own tree (`<root>/extensions/` and
`<root>/extensions/unratified/`) and writes its outputs into the current directory. So we **stage a
copy** in `build/` and add our files to it. Never write into `deps/`.

Run from the repository root inside the container (`tools/dev.sh` gives you a shell there):

```bash
# 1. Stage a copy (a few MB, one second) in build/, which is the build area inside tools/dev.sh.
O=$PWD/build/riscv-opcodes
rm -rf $O && mkdir -p $O
cp -r deps/riscv-opcodes/{src,extensions,arg_lut.csv,causes.csv,csrs.csv,csrs32.csv,encoding.h} $O/
cp encodings/rv*_xkm* $O/extensions/unratified/
# Kamui's extra field names and CSRs, once they exist:
#   cat encodings/arg_lut.xkm.csv >> $O/arg_lut.csv ; cat encodings/csrs.xkm.csv >> $O/csrs.csv

# 2. Generate for Kamui's ISA: base files + Xkm files
cd $O
BASE="rv_i rv64_i rv_m rv64_m rv_a rv64_a rv_f rv64_f rv_d rv64_d rv_zicsr rv_zifencei \
      rv_zfh rv64_zfh rv_zfhmin rv_d_zfhmin rv_zba rv64_zba rv_zbb rv64_zbb rv_zbs rv64_zbs \
      rv_zicond rv_system rv_s"
PYTHONPATH=src python3 -m riscv_opcodes -c -sverilog -rust -go -chisel $BASE 'unratified/rv*_xkm*'

# 3. Collision check against everything RISC-V International has published
PYTHONPATH=src python3 -m riscv_opcodes -c 'rv*' 'unratified/rv*'
```

The base list is Kamui's base ISA (RV64 I, M, A, F, D, Zfh, Zba, Zbb, Zbs, Zicond, plus Zicsr,
Zifencei and the privileged instructions).

Flags (from
[`deps/riscv-opcodes/src/riscv_opcodes/parse.py`](../../deps/riscv-opcodes/src/riscv_opcodes/parse.py),
lines 85 to 131):

| Flag | Output file |
|---|---|
| (always) | `instr_dict.json` |
| `-c` | `encoding.out.h` (`MATCH_*`, `MASK_*`, `CSR_*`, `CAUSE_*`, `DECLARE_INSN(...)`) |
| `-sverilog` | `inst.sverilog` (`localparam [31:0] NAME = 32'b...;` with `?` for don't-care) |
| `-chisel` / `-spinalhdl` | `inst.chisel` / `inst.spinalhdl` |
| `-rust` | `inst.rs` (`const MATCH_*`/`MASK_*`) |
| `-go` | `inst.go` |
| `-latex` | `instr-table.tex`, `priv-instr-table.tex` (hard-coded standard extensions only) |
| `-svg` | `inst.svg` (needs matplotlib) |
| `-pseudo` | also emit `$pseudo_op` entries |
| `--warn-overlap` | report overlaps as warnings instead of stopping |

Positional arguments are glob patterns over file names. Prefix `unratified/` for that folder.

## Input formats

One file per extension, named `rv_<ext>` (both RV32 and RV64), `rv64_<ext>` (RV64 only) or
`rv32_<ext>` (RV32 only). Kamui files are `encodings/rv_xkm<family>` and, for RV64-only
instructions, `encodings/rv64_xkm<family>`. File names must match `rv[0-9]*_...` (the `$pseudo_op`
regular expression depends on it).

Each line is one instruction: `name arg arg ... bitfield bitfield ...`.

```
# comment lines start with '#'; no inline comments
kmt.add1   rd rs1 rs2 31..25=0 14..12=0 6..2=0x02 1..0=3
```

- `hi..lo=value` assigns a range; `bit=value` assigns one bit. Values can be decimal, `0x` or `0b`.
- Operand names (`rd`, `rs1`, `rs2`, `rs3`, `imm12`, `imm12hi`/`imm12lo`, `bimm12hi`/`bimm12lo`,
  `imm20`, `jimm20`, `aq`, `rl`, `aqrl`, `fm`, `pred`, `succ`, `rm`, `csr`, `zimm`, `shamtd`, ...)
  come from `arg_lut.csv` (name, msb, lsb). A new field name (for example a scope field) must be
  added to the staged `arg_lut.csv`.
- Every one of the 32 bits must be covered exactly once, by a constant or an operand.
- `$pseudo_op rv_xkmwarp::kmw.shfl kmw.shfl.idx rd rs1 rs2 31..25=8 ...` defines an alias with
  extra fixed bits. It is checked against its base instruction and only emitted with `-pseudo`.
- `$import rv_xkmwarp::kmw.vote` reuses an instruction from another extension file (only regular
  instructions can be imported).
- Dots in names become underscores in every output.
- Custom-opcode values in this syntax: custom-0 `6..2=0x02`, custom-1 `6..2=0x0A`, custom-2
  `6..2=0x16`, custom-3 `6..2=0x1E`, always with `1..0=3`.

## Output formats

- `instr_dict.json`: `{ "kmt_add1": {"encoding": "0000000----------000-----0001011",
  "variable_fields": ["rd","rs1","rs2"], "extension": ["rv_xkmtest"], "match": "0xb",
  "mask": "0xfe00707f"}, ... }`. This is the file Kamui's own tools should read (spec tables,
  assembler macros, simulator decoder). Older documentation calls it `instr_dict.yaml`. The YAML
  output no longer exists, but JSON is valid YAML.
- `encoding.out.h`: a drop-in for Spike-style C/C++ decoders (`(insn & MASK_X) == MATCH_X`).
- `inst.sverilog`: for the RTL in the `kamui` repository.

## Worked example (real output)

Input files: [`docs/examples/riscv/opcodes/`](../examples/riscv/opcodes/) (`rv_xkmtest`,
`rv_xkmbad`, `rv_xkmclash`, `rv_xkmreserved`). The toy extension `rv_xkmtest`:

```
# Toy extension Xkmtest: two R-type instructions in custom-0 (opcode 0b0001011, 6..2=0x02).
kmt.add1   rd rs1 rs2 31..25=0 14..12=0 6..2=0x02 1..0=3
kmt.mix    rd rs1 rs2 31..25=1 14..12=0 6..2=0x02 1..0=3
```

Stage the copy with the toy file instead of `encodings/`, then generate and look at the outputs:

```bash
E=$PWD/docs/examples/riscv/opcodes
O=$PWD/build/riscv-opcodes
rm -rf $O && mkdir -p $O
cp -r deps/riscv-opcodes/{src,extensions,arg_lut.csv,causes.csv,csrs.csv,csrs32.csv,encoding.h} $O/
cp $E/rv_xkmtest $O/extensions/unratified/
cd $O
BASE="rv_i rv64_i rv_m rv64_m rv_a rv64_a rv_f rv64_f rv_d rv64_d rv_zicsr rv_zifencei \
      rv_zfh rv64_zfh rv_zfhmin rv_d_zfhmin rv_zba rv64_zba rv_zbb rv64_zbb rv_zbs rv64_zbs \
      rv_zicond rv_system rv_s"
PYTHONPATH=src python3 -m riscv_opcodes -c -sverilog -rust -go -chisel $BASE unratified/rv_xkmtest
grep -n KMT encoding.out.h
python3 -c "import json; d=json.load(open('instr_dict.json')); print(len(d), 'instructions'); [print(k, json.dumps(d[k])) for k in d if k.startswith('kmt')]"
grep -n KMT inst.sverilog
grep -n -i kmt inst.rs
```

Output:

```
$ PYTHONPATH=src python3 -m riscv_opcodes -c -sverilog -rust -go -chisel <base files> unratified/rv_xkmtest
fatal: not a git repository (or any parent up to mount point ...)
Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).
INFO:: encoding.out.h generated successfully
INFO:: inst.chisel generated successfully
INFO:: inst.sverilog generated successfully
INFO:: inst.rs generated successfully
INFO:: inst.go generated successfully
Extensions selected : ['rv_i', 'rv64_i', 'rv_m', 'rv64_m', 'rv_a', 'rv64_a', 'rv_f', 'rv64_f', 'rv_d', 'rv64_d', 'rv_zicsr', 'rv_zifencei', 'rv_zfh', 'rv64_zfh', 'rv_zfhmin', 'rv_d_zfhmin', 'rv_zba', 'rv64_zba', 'rv_zbb', 'rv64_zbb', 'rv_zbs', 'rv64_zbs', 'rv_zicond', 'rv_system', 'rv_s', 'unratified/rv_xkmtest']
exit=0
--- encoding.out.h
922:#define MATCH_KMT_ADD1 0xb
923:#define MASK_KMT_ADD1 0xfe00707f
924:#define MATCH_KMT_MIX 0x200000b
925:#define MASK_KMT_MIX 0xfe00707f
1852:DECLARE_INSN(kmt_add1, MATCH_KMT_ADD1, MASK_KMT_ADD1)
1853:DECLARE_INSN(kmt_mix, MATCH_KMT_MIX, MASK_KMT_MIX)
--- instr_dict.json
238 instructions
kmt_add1 {"encoding": "0000000----------000-----0001011", "variable_fields": ["rd", "rs1", "rs2"], "extension": ["rv_xkmtest"], "match": "0xb", "mask": "0xfe00707f"}
kmt_mix {"encoding": "0000001----------000-----0001011", "variable_fields": ["rd", "rs1", "rs2"], "extension": ["rv_xkmtest"], "match": "0x200000b", "mask": "0xfe00707f"}
--- inst.sverilog
165:  localparam [31:0] KMT_ADD1           = 32'b0000000??????????000?????0001011;
166:  localparam [31:0] KMT_MIX            = 32'b0000001??????????000?????0001011;
--- inst.rs
325:const MATCH_KMT_ADD1: u32 = 0xb;
326:const MASK_KMT_ADD1: u32 = 0xfe00707f;
327:const MATCH_KMT_MIX: u32 = 0x200000b;
328:const MASK_KMT_MIX: u32 = 0xfe00707f;
```

(`exit=` is the shell's `$?`; the `---` lines separate the four `grep`/`python3` commands.) The two
"fatal: not a git repository" lines are harmless. The C emitter runs `git log` to stamp the header,
and the staged copy (in the build area, a different filesystem) has no `.git`. A re-run on the build
host iacoma231 on 2026-10-31 through `tools/dev.sh` gave the same output.

Next, a check against every standard and unratified file, then three deliberate mistakes. Each
mistake file is copied into `extensions/unratified/` and removed again afterwards:

```bash
PYTHONPATH=src python3 -m riscv_opcodes -c 'rv*' 'unratified/rv*'
cp $E/rv_xkmbad extensions/unratified/
PYTHONPATH=src python3 -m riscv_opcodes -c $BASE unratified/rv_xkmtest unratified/rv_xkmbad
PYTHONPATH=src python3 -m riscv_opcodes --warn-overlap -c $BASE unratified/rv_xkmtest unratified/rv_xkmbad
rm extensions/unratified/rv_xkmbad
cp $E/rv_xkmclash extensions/unratified/
PYTHONPATH=src python3 -m riscv_opcodes -c $BASE unratified/rv_xkmtest unratified/rv_xkmclash
rm extensions/unratified/rv_xkmclash
cp $E/rv_xkmreserved extensions/unratified/
PYTHONPATH=src python3 -m riscv_opcodes -c $BASE unratified/rv_xkmtest unratified/rv_xkmreserved
grep -n KMT_OOPS encoding.out.h
rm extensions/unratified/rv_xkmreserved
```

Output:

```
--- full check against every standard and unratified file
INFO:: encoding.out.h generated successfully
Extensions selected : ['rv*', 'unratified/rv*']
exit=0

--- deliberate overlap inside the Xkm space   (rv_xkmbad: kmt.bad rd rs1 imm12 14..12=0 6..2=0x02 1..0=3)
ERROR:: Instruction kmt_bad in extension rv_xkmbad overlaps with kmt_add1 in ['rv_xkmtest']
exit=1

--- same, with --warn-overlap
WARNING:: Instruction kmt_bad in extension rv_xkmbad overlaps with kmt_add1 in ['rv_xkmtest']
WARNING:: Instruction kmt_bad in extension rv_xkmbad overlaps with kmt_mix in ['rv_xkmtest']
...
exit=0

--- deliberate clash with a standard instruction   (rv_xkmclash: ADD's exact encoding)
ERROR:: Instruction kmt_clash in extension rv_xkmclash overlaps with add in ['rv_i']
exit=1

--- instruction in a RESERVED major opcode: NOT caught   (rv_xkmreserved: 6..2=0x1A = 0b1101011)
INFO:: encoding.out.h generated successfully
exit=0
926:#define MATCH_KMT_OOPS 0x6b
927:#define MASK_KMT_OOPS 0xfe00707f
```

(Selected-extension lines trimmed.) In error mode the tool stops at the first overlap. Use
`--warn-overlap` to list them all. The last case shows that the tool does **not** know which major
opcodes are reserved; Kamui needs its own check for that (check 3 below).

## Limitations and gotchas

- Out-of-tree directories are not supported. Stage a copy (above).
- 32-bit instructions only. 48-bit and 64-bit encodings cannot be expressed, and bit positions
  above 31 are not even rejected cleanly.
- The overlap check only sees the files you select, and it does not know which major opcodes are
  custom or reserved (shown above).
- Overlaps across different base ISAs (`rv32_*` against `rv64_*`) are allowed silently.
- Instruction names must be unique across all selected files within one base ISA.
- LaTeX tables ignore non-standard extensions. Generate Kamui spec tables from `instr_dict.json`.
- CSR names and new field names live in CSV files of the staged copy. Keep Kamui's additions in
  separate files and append them.

## How Kamui uses it

The Kamui encodings live in `encodings/rv_xkm<family>` files, one per Xkm extension family. A planned
script, `tools/encodings/gen.sh`, will stage the copy, append `encodings/arg_lut.xkm.csv` and
`encodings/csrs.xkm.csv`, run the two generation commands above, and copy `encoding.out.h`,
`instr_dict.json` and `inst.sverilog` into `encodings/generated/`.

Checks the encodings must pass:

1. generation with the Kamui base files plus all Xkm files exits 0;
2. generation with `'rv*' 'unratified/rv*'` plus all Xkm files exits 0;
3. our own check: every Xkm entry in `instr_dict.json` has `encoding[-7:]` in
   {`0001011`, `0101011`, `1011011`, `1111011`} (custom-0 to custom-3), unless it is listed in an
   explicit, documented exception list (open question: whether Kamui will use any non-custom
   opcode space at all);
4. the committed `encodings/generated/` files equal a fresh generation (a CI diff).

Other users of the generated files:

- The Sail model: its `encdec` clauses are compared with `instr_dict.json` (see [sail.md](sail.md)).
- The C++ functional simulator: its decoder includes `encodings/generated/encoding.out.h`.
- The assembler macros for `.insn` (see [binutils-insn.md](binutils-insn.md)) are generated from the
  same files.

## References

- <https://github.com/riscv/riscv-opcodes> README (file format, `$pseudo_op`, `$import`, outputs).
- [`deps/riscv-opcodes/src/riscv_opcodes/shared_utils.py`](../../deps/riscv-opcodes/src/riscv_opcodes/shared_utils.py)
  (checks and overlap logic),
  [`constants.py`](../../deps/riscv-opcodes/src/riscv_opcodes/constants.py) (whitelists),
  [`parse.py`](../../deps/riscv-opcodes/src/riscv_opcodes/parse.py) (command line).

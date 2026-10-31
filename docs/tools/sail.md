# Sail and sail-riscv

## What it is

**Sail** is a language for writing instruction-set semantics. Each instruction is described by its
encoding, its assembly syntax and its execution, in readable pseudocode with precise types. The Sail
compiler (`sail`) type-checks the description (using the Z3 SMT solver) and translates it into an
executable emulator (C or C++), documentation (JSON bundle, HTML, LaTeX), SMT problems, and
theorem-prover definitions (Isabelle, Rocq, Lean).

**sail-riscv** is the official RISC-V model written in Sail. Built with `sail --cpp`, it becomes the
emulator `sail_riscv_sim`. The Kamui golden model is sail-riscv plus the Xkm extension files, driven
lane by lane by a SIMT scheduler (see [How Kamui uses it](#how-kamui-uses-it)). The source is in
[`deps/sail-riscv`](../../deps/sail-riscv) (read-only).

## Where it runs

In the dev container (see [devcontainer.md](devcontainer.md)). Sail is the 0.20.3 binary release in
`/opt/sail` (on `PATH`), with its runtime library in `/opt/sail/share/sail/lib`. Builds need CMake
3.20+, Ninja, a C++17 compiler, GMP (`libgmp-dev`, present) and network access the first time (CMake
`FetchContent` downloads CLI11, softfloat, jsoncons, ELFIO and asio into the build directory).

Always put the build directory under `build/`. Inside [`tools/dev.sh`](../../tools/dev.sh) that
directory is the build area on the build host (see [docs/development.md](../development.md)). Never
build inside `deps/sail-riscv`. Delete the build with `tools/build-area.sh clean` (see
[`tools/build-area.sh`](../../tools/build-area.sh)) when you no longer need it.

## Version pinned

- Sail 0.20.3 (`sail --version`: `Sail 0.20.3 (sail2 @ 60695b1ea377048f0adc39c62671cd099b2ed9f6)`).
  sail-riscv requires exactly this version
  ([`deps/sail-riscv/cmake/sail_required_version.txt`](../../deps/sail-riscv/cmake/sail_required_version.txt)).
- sail-riscv at commit `fc074f9` (2026-10-29), the commit of the `deps/sail-riscv` submodule.

## Commands we use

Run these from the repository root inside the container (`tools/dev.sh` gives you a shell there).

```bash
# Configure and build the emulator (system GMP, no test-suite download)
cmake -S deps/sail-riscv -B build/sail-riscv -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo -DDOWNLOAD_GMP=FALSE -DENABLE_RISCV_TESTS=FALSE
cmake --build build/sail-riscv --target sail_riscv_sim
SIM=build/sail-riscv/c_emulator/sail_riscv_sim

# Run a bare-metal RV64 ELF (linked at 0x80000000, tohost symbol for exit)
$SIM prog.elf
$SIM --trace-instr --inst-limit 100 prog.elf      # instruction trace, bounded run
$SIM --trace prog.elf                            # instructions + registers + CSRs + memory (see --help)

# Configuration
$SIM --print-default-config > my.json             # edit, then:
$SIM --config my.json prog.elf
$SIM --config-override extra.json prog.elf         # merge a few keys over the default
$SIM --print-config-schema                         # JSON schema generated from the model
$SIM --print-isa-string

# Documentation generated from the model (JSON bundle + HTML tarball)
cmake --build build/sail-riscv --target generated_sail_riscv_docs

# Direct use of the compiler
sail --list-files deps/sail-riscv/model/riscv.sail_project    # files in a project
sail deps/sail-riscv/model/riscv.sail_project sail/model/xkm.sail_project --all-modules   # type-check with an out-of-tree project
```

The last command shows how the planned Kamui project file (`sail/model/xkm.sail_project`) will be
type-checked together with the stock model.

`deps/sail-riscv/build_simulator.sh` does the same as the first two commands, but it builds in
`deps/sail-riscv/build` and downloads GMP by default. **Do not use it**: it writes into `deps/`.

To run the two build commands without opening a shell:

```bash
tools/dev.sh 'cmake -S deps/sail-riscv -B build/sail-riscv -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DDOWNLOAD_GMP=FALSE -DENABLE_RISCV_TESTS=FALSE && cmake --build build/sail-riscv --target sail_riscv_sim'
```

## Input formats

- **Sail sources** (`.sail`), organized by a **project file** (`.sail_project`) that lists modules,
  their files, and `requires`/`before`/`after` relations. Several project files can be given on one
  command line and are merged. That is how an out-of-tree extension is added (Sail manual, modules
  chapter:
  <https://github.com/rems-project/sail/blob/0.20.3/doc/asciidoc/modules.adoc#L98-L117>).
- **Configuration JSON** for the emulator. The keys come from `config ...` expressions in the model.
  The template, with comments, is
  [`deps/sail-riscv/config/config.json.in`](../../deps/sail-riscv/config/config.json.in). The
  emulator validates the file against the generated schema before running.
- **ELF** programs (RV64 for the RV64 configuration). Symbols used: `tohost` (HTIF exit and
  console), and optionally `begin_signature`/`end_signature` (riscv-arch-test signatures). The HTIF
  convention is the same as Spike's (see [spike.md](spike.md#input-formats)), so one ELF runs on both.

### What an instruction looks like

From
[`deps/sail-riscv/model/extensions/Zibi/zibi_insts.sail`](../../deps/sail-riscv/model/extensions/Zibi/zibi_insts.sail):

```
function clause currentlyEnabled(Ext_Zibi) = hartSupports(Ext_Zibi)

union clause instruction = BITYPE : (bits(13), bits(5), regidx, biop)

mapping clause encdec = BITYPE(imm @ 0b0, cimm, rs1, op)
  <-> imm[11] @ imm[9..4] @ cimm @ encdec_reg(rs1) @ encdec_biop(op) @ imm[3..0] @ imm[10] @ 0b1100011
  when currentlyEnabled(Ext_Zibi)

function clause execute BITYPE(imm, cimm, rs1, op) = {
  let cimmext : xlenbits = if cimm == zeros() then ones() else zero_extend(cimm);
  let taken : bool = match op { BEQI => X(rs1) == cimmext, BNEI => X(rs1) != cimmext };
  if taken then jump_to(PC + sign_extend(imm)) else RETIRE_SUCCESS
}

mapping clause assembly = BITYPE(imm, cimm, rs1, op)
  <-> bitype_mnemonic(op) ^ spc() ^ reg_name(rs1) ^ sep() ^ hex_bits_5(cimm) ^ sep() ^ hex_bits_signed_13(imm)
```

An Xkm instruction is written the same way, with `0b0001011` (custom-0) at the end of its `encdec`
clause. The procedure for adding an extension and its CSRs is in
[`deps/sail-riscv/doc/AddingExtensions.md`](../../deps/sail-riscv/doc/AddingExtensions.md).

## Output formats

- `sail_riscv_sim` stdout: `HTIF located at ...`, the program's console output, then `SUCCESS` or
  `FAILURE: <code>`. The exit status is 0 or 1.
- `--trace-instr`: one line per instruction, `[<step>] [<priv>]: 0x<pc> (0x<bits>) <assembly>`.
  Other `--trace-*` flags add register writes (`x10 <- 0x...`), memory accesses, CSR accesses and
  exceptions.
- Generated files in the build directory: `sail_riscv_model.{h,cpp}` (the C++ model, class
  `hart::Model`), `sail_riscv_config_schema.json`, `model/sail_riscv_model.json` (documentation
  bundle), `model/sail_riscv_html.tgz`.

## Worked example (real output)

Input files:

- [`docs/examples/riscv/baremetal/`](../examples/riscv/baremetal/): `exit.S`, `xkmtest.S`,
  `htif.inc`, `link.ld`;
- [`docs/examples/riscv/sail/`](../examples/riscv/sail/): `lanes.S`, `multilane.cpp`;
- [`docs/examples/riscv/asm/xkm-macros.inc`](../examples/riscv/asm/xkm-macros.inc) (used by
  `xkmtest.S`).

All outputs go to `build/examples/riscv/`. Start a shell with `tools/dev.sh` at the repository root
and set:

```bash
ISA=rv64imafd_zicsr_zifencei_zfh_zba_zbb_zbs_zicond
E=docs/examples/riscv
OUT=$PWD/build/examples/riscv
SIM=build/sail-riscv/c_emulator/sail_riscv_sim
mkdir -p $OUT
```

### 1. Build `sail_riscv_sim`

First run, on iacoma227:

```
$ cmake -S deps/sail-riscv -B build/sail-riscv -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DDOWNLOAD_GMP=FALSE -DENABLE_RISCV_TESTS=FALSE
-- Found GMP: /usr/lib/x86_64-linux-gnu/libgmp.so
-- Found sail: /opt/sail/bin/sail
-- Sail library directory: /opt/sail/bin/../share/sail
-- jsoncons v1.8.1
-- Sail version: Sail 0.20.3 (sail2 @ 60695b1ea377048f0adc39c62671cd099b2ed9f6)
-- Configuring done (177.4s)
-- Generating done (1.0s)
-- Build files have been written to: build/sail-riscv
real	2m59.139s

$ cmake --build build/sail-riscv --target sail_riscv_sim
...
[383/384] Linking CXX static library c_emulator/libriscv_model.a
[384/384] Linking CXX executable c_emulator/sail_riscv_sim
The configuration in build/sail-riscv/config/rv64d_v512_e64.json is valid.
...
real	17m51.769s
user	13m11.772s
sys	6m53.520s
```

Timings:

- **iacoma227** (shared machine under load, build directory on NFS): about **3 minutes to
  configure** (dependency downloads and `sail --list-files`) and **18 minutes to build**.
- **iacoma231** (the build host), re-run on 2026-10-31 through `tools/dev.sh` into `build/sail-riscv`
  (local `/scratch` disk): **8.6 seconds to configure and 12.5 minutes to build**
  (`real 12m33.978s`), 370 MB.

The Sail step dominates either way. On iacoma227, about 16 minutes of the build (mostly waiting on
Z3 calls) is the Sail compiler writing `sail_riscv_model.cpp` (19 MB, 591,422 lines) and its
19,597-line header. Compiling the C++ takes about 2 minutes on many cores. Any change to a `.sail`
file reruns the Sail step.

The build directory ends up at about 385 MB (objects plus the generated docs of step 4).
`deps/sail-riscv` stays clean (`git status --short` is empty afterwards). The compiler prints
harmless `-Walloc-size` style warnings from `sail.h`.

### 2. Run a bare-metal ELF

`exit.S` is the same program as in [spike.md](spike.md#1-bare-metal-elf): it computes 6 * 7, prints
`OK` through HTIF and exits with 0.

```bash
riscv64-unknown-elf-gcc -march=$ISA -mabi=lp64d -nostdlib -nostartfiles -static -T $E/baremetal/link.ld \
  -Wa,-I$E/baremetal -o $OUT/exit.elf $E/baremetal/exit.S
riscv64-unknown-elf-gcc -march=$ISA -mabi=lp64d -nostdlib -nostartfiles -static -T $E/baremetal/link.ld \
  -Wa,-I$E/baremetal -Wa,-I$E/asm -o $OUT/xkmtest.elf $E/baremetal/xkmtest.S
```

```
$ $SIM --build-info
Sail RISC-V release: 0.16
Sail RISC-V git: unknown commit
Sail: Sail 0.20.3 (sail2 @ 60695b1ea377048f0adc39c62671cd099b2ed9f6)
C++ compiler: GNU 13.3.0
CLI11: 2.6.2
ELFIO: 3.12
JSONCONS: 1.8.1
ASIO: 103600

$ $SIM $OUT/exit.elf
OK
HTIF located at 0x80001000
Entry point: 0x80000000
SUCCESS
exit=0

$ $SIM --trace-instr --inst-limit 6 $OUT/exit.elf
HTIF located at 0x80001000
Entry point: 0x80000000
[0] [M]: 0x0000000080000000 (0x00600513) addi x10, x0, 0x6                          _start+0
[1] [M]: 0x0000000080000004 (0x00700593) addi x11, x0, 0x7                          _start+4
[2] [M]: 0x0000000080000008 (0x02B50633) mul x12, x10, x11                          _start+8
[3] [M]: 0x000000008000000C (0x00001417) auipc x8, 0x1                              _start+12
[4] [M]: 0x0000000080000010 (0x03C40413) addi x8, x8, 0x3c                          _start+16
[5] [M]: 0x0000000080000014 (0x00044683) lbu x13, 0x0(x8)                           _start+20
exit=0
```

(`exit=` is the shell's `$?`, printed after each command.) `OK` appears before the HTIF lines only
because the console and the log are buffered differently. `Sail RISC-V git: unknown commit` appears
when git cannot read the `deps/sail-riscv` history from inside the container (for example when only
a worktree is mounted, without the main repository's `.git`). The release number (0.16) is correct
either way.

The stock model does not know custom-0, so the Xkm test traps. There is no trap handler, so it then
loops on fetch faults at address 0 until the instruction limit:

```
$ $SIM --trace-exception --inst-limit 40 $OUT/xkmtest.elf
HTIF located at 0x80001000
Entry point: 0x80000000
trapping from M to M to handle illegal-instruction
handling exc#illegal-instruction at priv M | tval=0x0000000000C5868B | tval2=0x0000000000000000 | tinst=0x0000000000000000
trapping from M to M to handle fetch-access-fault
...
```

The default configuration is **not** Kamui's ISA. `--print-isa-string` prints
`rv64imafdcbvh_zic64b_..._zicond_zicsr_zifencei_..._zfh_zfhmin_zca_zcb_zcd_..._sdtrig` (C, V, H and
many more enabled). The Kamui model must ship a configuration with C, V, H and the unused extensions
turned off. `--print-default-config` prints JSON **with `//` comments**. Strip them before feeding it
to a strict JSON parser (Python's `json` fails on it).

### 3. Many lanes in one process (`multilane`)

This example shows that one process can hold many independent hart models ("lanes") that share one
memory. That is the basis of the per-lane stepping design of the Kamui golden model.
`multilane.cpp` (about 70 lines) links against the build's `libriscv_model.a`. It creates N
`ModelImpl` objects, loads one ELF into the shared memory, sets `a0` = lane id in each, steps all
lanes round-robin for 8 steps, then prints each lane's state and the shared `results[]` array.
`lanes.S` computes `a1 = a0 * a0 + 1` and stores it to `results[a0]`. The core of `multilane.cpp`:

```cpp
sail_config_set_string(get_default_config());          // process-global config
for (int i = 0; i < nlanes; ++i) {                      // one hart object per lane
  lane.push_back(std::make_unique<ModelImpl>());
  lane[i]->init_platform_constants();
  lane[i]->model_init();
}
ELF elf = ELF::open(argv[1]);                           // load once into the shared memory
elf.load([](uint64_t a, const uint8_t *d, uint64_t n) { for (uint64_t i = 0; i < n; ++i) write_mem(a + i, d[i]); });
for (int i = 0; i < nlanes; ++i) { lane[i]->init_sail(elf.entry(), "", std::nullopt); lane[i]->set_xreg(10, i); }
for (int64_t step = 0; step < 8; ++step)                // round-robin, one instruction per lane per turn
  for (int i = 0; i < nlanes; ++i) lane[i]->try_step(step, false);
...
lane.back()->model_fini();                              // ONCE: it frees process-global state
```

`multilane.cpp` must be compiled with the same `-I`, `-D`, `-std`, `-O`, `-f` and `-g` flags as
`riscv_model_impl.cpp` in the sail-riscv build. The flags are read from the build's
`compile_commands.json`:

```bash
SAILB=$PWD/build/sail-riscv
riscv64-unknown-elf-gcc -march=$ISA -mabi=lp64d -nostdlib -nostartfiles -static -T $E/baremetal/link.ld \
  -o $OUT/lanes.elf $E/sail/lanes.S

python3 - "$SAILB" "$PWD/$E/sail/multilane.cpp" "$OUT/multilane.o" <<'PY'
import json, shlex, subprocess, sys
build, src, obj = sys.argv[1:]
cc = json.load(open(build + '/compile_commands.json'))
e = [c for c in cc if c['file'].endswith('riscv_model_impl.cpp')][0]
args = shlex.split(e['command'])
flags, i = [], 1
while i < len(args):
    if args[i] == '-isystem':
        flags += args[i:i + 2]; i += 2; continue
    if args[i].startswith(('-I', '-D', '-std', '-O', '-f', '-g')):
        flags.append(args[i])
    i += 1
subprocess.run([args[0], *flags, '-c', src, '-o', obj], check=True, cwd=e['directory'])
PY

(cd $SAILB && c++ -O2 $OUT/multilane.o -o $OUT/multilane c_emulator/libriscv_model.a \
   dependencies/softfloat/libsoftfloat.a sail_runtime/libsail_runtime.a -lgmp)
```

Run:

```
$ $OUT/multilane $OUT/lanes.elf 4
lane 0: pc=0x8000001c a0=0 a1=1
lane 1: pc=0x8000001c a0=1 a1=2
lane 2: pc=0x8000001c a0=2 a1=5
lane 3: pc=0x8000001c a0=3 a1=10
results[0] = 1
results[1] = 2
results[2] = 5
results[3] = 10
exit=0
```

Each lane kept its own registers while sharing one memory. With 32 lanes the program also works
(`lane 31: ... a1=962`). The whole process peaks at about 15 MB resident memory (11 MB with one
lane), so 32 hart objects cost only a few MB.

Rules learned from reading the generated code (`build/sail-riscv/sail_riscv_model.cpp`):

- Registers are members of `class Model : protected PlatformInterface` (`sail_riscv_model.h:4917`;
  for example `sbits zPC` at line 16533, `sbits zx1` at line 16539).
- But about 15,700 **preallocated GMP scratch values** (`lbits zghz30;`, `sail_int zghz31;`, ...) are
  defined at namespace scope in the `.cpp`, shared by all objects. They are created by `startup_*`
  calls in every `model_init()` and freed by `finish_*` calls in `model_fini()`. Scratch values are
  only live inside one function call, so sharing them is correct when lanes are stepped from **one
  thread**. Each extra `model_init()` re-creates them (a small leak, harmless).
- `model_fini()` also calls `cleanup_rts()`, which frees the **shared memory** (`kill_mem()`) and the
  library temporaries. Call it once, after all lanes have stopped. Calling it per lane would destroy
  the other lanes' memory and double-free the scratch values.

### 4. Documentation from the model

```
$ cmake --build build/sail-riscv --target generated_sail_riscv_docs
...
[3/3] Building documentation JSON from Sail model
Warning: Unused variable
/opt/sail/bin/../share/sail/lib/concurrency_interface/read_write_v2.sail:291.26-33:
...
real	2m5.008s

$ ls -la build/sail-riscv/model/
drwxr-xr-x. 12 dev dev    4096 Oct 30 03:30 html_docs
-rw-r--r--.  1 dev dev  662569 Oct 30 03:30 sail_riscv_html.tgz
-rw-r--r--.  1 dev dev 6680464 Oct 30 03:31 sail_riscv_model.json
```

The JSON bundle (6.7 MB) has these top-level keys and entry counts:

```
['version', 'embedding', 'hashes', 'functions', 'mappings', 'vals', 'types', 'registers', 'lets', 'anchors', 'spans']
functions 1670, mappings 425, vals 2281, types 417, registers 213, lets 234
```

Scattered definitions keep one entry per clause. `functions["execute"]["function"]` is a list of 409
clauses and `mappings["encdec"]["mapping"]` a list of 405. Each clause has `source.contents` (the
Sail text), `source.file`, `source.loc`, the AST `pattern` (constructor name such as
`ZICOND_RTYPE` and its arguments), `body`, the module `path` (for example
`["extensions", "Zicond", "Zicond_insts"]`) and, for `$[split]` clauses, `splits` (one specialized
body per enum value). Example, abbreviated:

```json
{"number": 390,
 "source": {"contents": "function clause execute ZICOND_RTYPE(rs2, rs1, rd, op) = {\n  let condition : bool = match op {...",
            "file": "extensions/Zicond/zicond_insts.sail", "loc": [32, 1171, 1171, 39, 1409, 1410]},
 "pattern": {"type": "app", "id": "ZICOND_RTYPE", "patterns": [...]},
 "body": {"contents": "  let condition : bool = match op {\n    CZERO_EQZ => X(rs2) == zeros(),\n ..."},
 "path": ["extensions", "Zicond", "Zicond_insts"],
 "splits": {"CZERO_EQZ": "...", "CZERO_NEZ": "..."}}
```

To build Kamui's instruction pages, select the clauses whose `path` starts with an Xkm module, group
the `encdec`, `execute` and `assembly` clauses by constructor (`pattern.id`), and print them as
Markdown. `html_docs/` is a browsable HTML rendering of every source file.

## Limitations and gotchas

- The first configure downloads dependencies and runs `sail --list-files`. The first build runs the
  Sail compiler on the whole model (see the timings above). Incremental rebuilds after changing one
  `.sail` file still regenerate and recompile the whole C++ model.
- The stock model treats custom-0 to custom-3 as illegal instructions.
- `build_simulator.sh` writes into the source tree. Use explicit `cmake -S ... -B build/...`.
- The configuration is process-global and validated against a schema generated from the model.
  Adding `config` keys in Xkm code means shipping a matching configuration file.
- Single-threaded: Sail's runtime has static temporaries. Step all lanes from one thread.
- Memory is one process-global sparse array shared by every model object.
- Do not make build scripts depend on `git describe` of `deps/sail-riscv` working inside the
  container. When git cannot see the history, the version string falls back to `unknown commit`
  (shown above), which is harmless.

## How Kamui uses it

The Kamui golden model is sail-riscv plus one Sail module per Xkm extension family. Sail models one
hart. Warps, barriers, `mbarrier` phases, async engines and tensor units are modelled by an external
SIMT scheduler that steps per-lane Sail state. The planned layout:

1. `sail/model/xkm.sail_project` with one module per Xkm family, each `before postlude`, and files in
   `sail/model/<family>/` that follow
   [`deps/sail-riscv/CODE_STYLE.md`](../../deps/sail-riscv/CODE_STYLE.md).
2. `sail/CMakeLists.txt` that reuses `deps/sail-riscv` (as a CMake subdirectory, or by reproducing
   [`deps/sail-riscv/model/CMakeLists.txt`](../../deps/sail-riscv/model/CMakeLists.txt) lines 71 to
   153), adds the Xkm project file, and adds a Kamui platform-interface header for warp-level
   callbacks.
3. `sail/config/kamui.json`: the default configuration plus `extensions.Xkm*.supported` keys. The
   stock default configuration will not validate once Xkm code reads `config` keys.
4. `sail/lane/`: one `LaneModel` object per lane and a small SIMT scheduler that steps 32 lanes.
   The `multilane` example above is its seed.
5. Generated documentation: the JSON bundle filtered to Xkm clauses and converted to Markdown in
   `spec/generated/`.

Checks proposed for the model:

- every Xkm instruction in `encodings/` has an `encdec` clause with the same match and mask (a script
  that compares `instr_dict.json` from [riscv-opcodes](riscv-opcodes.md) with the JSON bundle);
- `sail_riscv_sim` built with Xkm still passes the stock riscv-tests (no regression);
- the tier 1 test programs produce the same per-lane register traces on the Sail lane driver and on
  the C++ functional simulator.

Other uses:

- The C++ functional simulator is cross-checked against Sail at lane level. The `--trace-instr`
  format is a model for the simulator's own trace.
- The conformance runner can measure coverage of the Xkm clauses with `--sailcov-file` (this needs
  a build configured with `-DCOVERAGE=ON`).

## References

- Sail manual: <https://alasdair.github.io/manual.html> (modules, configuration, `--doc`). Source:
  <https://github.com/rems-project/sail/tree/0.20.3/doc/asciidoc>.
- Sail 0.20 changelog (C++ back end):
  <https://github.com/rems-project/sail/blob/0.20.3/CHANGELOG.md#L69-L100>.
- sail-riscv: [`README.md`](../../deps/sail-riscv/README.md),
  [`doc/ReadingGuide.md`](../../deps/sail-riscv/doc/ReadingGuide.md),
  [`doc/AddingExtensions.md`](../../deps/sail-riscv/doc/AddingExtensions.md),
  [`doc/ChangeLog.md`](../../deps/sail-riscv/doc/ChangeLog.md).
- A. Armstrong et al., "ISA Semantics for ARMv8-A, RISC-V, and CHERI-MIPS", POPL 2019:
  <https://www.cl.cam.ac.uk/~pes20/sail/sail-popl2019.pdf>.
- Asciidoctor plugin for Sail documentation bundles: <https://github.com/Alasdair/asciidoctor-sail>.

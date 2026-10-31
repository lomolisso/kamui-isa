# Spike (riscv-isa-sim) and pk

## What it is

Spike is the reference functional RISC-V simulator. It executes instructions one by one, with no
timing, very fast. pk (the proxy kernel) is a tiny kernel that runs user-mode Linux-style programs
on Spike and forwards their system calls (`write`, `exit`, ...) to the host. For Kamui, Spike is:

- a quick way to run bare-metal RISC-V test programs before Kamui's own simulator exists;
- a host for **custom-instruction plugins** (`--extlib`), so hand-written Xkm programs can run
  early (lane-local instructions only; Spike has no warps);
- a possible **third reference** and trace format (`--log-commits`) next to Sail and the Kamui C++
  functional simulator.

Source: <https://github.com/riscv-software-src/riscv-isa-sim> (Spike) and
<https://github.com/riscv-software-src/riscv-pk> (pk).

## Where it runs

In the dev container (see [devcontainer.md](devcontainer.md)). Spike and pk are installed in
`/opt/riscv` (on `PATH`):

- headers in `/opt/riscv/include/{riscv,fesvr,softfloat,fdt}`;
- libraries `libriscv.so`, `libsoftfloat.so`, `libcustomext.so` in `/opt/riscv/lib`;
- pk in `/opt/riscv/riscv64-unknown-elf/bin/pk`.

## Version pinned

- Spike `1.1.1-dev`, riscv-isa-sim commit
  [`4c6a9bc79dab80616932949707e7c0471d8e9e54`](https://github.com/riscv-software-src/riscv-isa-sim/tree/4c6a9bc79dab80616932949707e7c0471d8e9e54),
  built in the image ([`.devcontainer/Dockerfile`](../../.devcontainer/Dockerfile), stage `spike`).
- Building Spike at this commit **requires its nested submodule `berkeley-softfloat-3`**. The image
  build initializes it inside the container (`git submodule update --init --depth 1
  berkeley-softfloat-3`).
- pk commit `9c61d29846d8521d9487a57739330f9682d5b542`, built with picolibc for
  `rv64imafd_zicsr_zifencei`.

In the source links below, `riscv-isa-sim@4c6a9bc` means a file of that repository at that commit.

## Commands we use

```bash
# bare-metal ELF (linked at 0x80000000, exits through the HTIF tohost word)
spike --isa=rv64imafd_zicsr_zifencei_zfh_zba_zbb_zbs_zicond prog.elf

# instruction trace (-l) plus register/memory writes (--log-commits), to stderr or --log=<file>
spike -l --log-commits --isa=... prog.elf 2> trace.txt

# with a custom-instruction plugin
spike --extlib=libkmtest.so --isa=rv64imafd_zicsr_zifencei_zfh_zba_zbb_zbs_zicond_xkmtest prog.elf

# user-mode program on the proxy kernel
spike pk prog.elf

# bounded run (stops after N instructions, exit status 0)
spike --instructions=1000 ...
```

The ISA string `rv64imafd_zicsr_zifencei_zfh_zba_zbb_zbs_zicond` is Kamui's base ISA (no C, no V).

Other useful options (`spike --help`): `-p<n>` harts, `-m<MiB>` or `-m<base:size,...>` memory
layout (default 2 GiB at `0x80000000`), `--pc=<addr>`, `-d` interactive debugger, `--dump-dts`,
`--extension=<name>` (attach a registered plugin without putting it in the ISA string).

## Input formats

- **Bare-metal ELF**: an RV64 ELF linked at `0x80000000` (the boot ROM at `0x1000` jumps there). It
  must define the symbols `tohost` and `fromhost` (64-bit words, usually in a `.tohost` section).
  Writing `(code << 1) | 1` to `tohost` ends the simulation with exit status `code`. Writing
  `0x0101000000000000 | ch` prints the character `ch` (device 1 = console, command 1 = putchar);
  wait until `tohost` reads 0 before the next write. The same convention works on `sail_riscv_sim`,
  so one ELF runs on both (see [sail.md](sail.md)).
- **pk program**: a static user-mode RV64 ELF. System calls use Linux numbers in `a7`
  (`write` = 64, `exit` = 93).
- **Plugin**: a shared library that calls `REGISTER_EXTENSION(<name>, ...)`. Its name is the ISA
  suffix without the leading `x` (`_xkmtest` becomes `kmtest`).
- **ISA string**: lower case, standard extensions first, then `_x<name>`. See the naming chapter
  ("ISA Extension Naming Conventions") of the RISC-V unprivileged specification,
  <https://github.com/riscv/riscv-isa-manual>.

## Output formats

- Program output (HTIF console or pk `write`) goes to stdout. The exit status is the HTIF code or
  the pk `exit` code.
- `-l`: one line per executed instruction:
  `core   0: 0x0000000080000000 (0x00600513) li      a0, 6`.
- `-l --log-commits`: adds a commit line per retired instruction:
  `core   0: 3 0x0000000080000008 (0x00c5868b) x13 0x000000000000002a`.
  The fields are hart, privilege (3 = M), PC, instruction bits, then each written register and
  value, and `mem <addr> [<value>]` for loads and stores
  ([riscv-isa-sim@4c6a9bc `riscv/execute.cc`, lines 62 to 160](https://github.com/riscv-software-src/riscv-isa-sim/blob/4c6a9bc79dab80616932949707e7c0471d8e9e54/riscv/execute.cc#L62-L160)).
  Floating-point writes appear as `f<n>`, CSR writes as `c<addr>_<name>`.
- Exceptions appear in `-l` output as `core   0: exception trap_illegal_instruction, epc ...` and
  `tval ...`.

## Worked example (real output)

Input files:

- [`docs/examples/riscv/baremetal/`](../examples/riscv/baremetal/): `exit.S`, `xkmtest.S`,
  `htif.inc` (the `tohost`/`fromhost` words), `link.ld` (links at `0x80000000`);
- [`docs/examples/riscv/spike/`](../examples/riscv/spike/): `kmtest.cc`, `pk-hello.S`;
- [`docs/examples/riscv/asm/xkm-macros.inc`](../examples/riscv/asm/xkm-macros.inc) (the `.insn`
  macros, see [binutils-insn.md](binutils-insn.md)).

All outputs go to `build/examples/riscv/`. Start a shell with `tools/dev.sh` at the repository root
and set:

```bash
ISA=rv64imafd_zicsr_zifencei_zfh_zba_zbb_zbs_zicond
E=docs/examples/riscv
OUT=$PWD/build/examples/riscv
mkdir -p $OUT
```

In the outputs below, `exit=` is the shell's `$?`, printed after each command.

### 1. Bare-metal ELF

`exit.S` computes 6 * 7, prints `OK` through HTIF, and exits with 0 if the product is 42.

```
$ riscv64-unknown-elf-gcc -march=$ISA -mabi=lp64d -nostdlib -nostartfiles -static \
    -T $E/baremetal/link.ld -Wa,-I$E/baremetal -o $OUT/exit.elf $E/baremetal/exit.S
$ spike --isa=$ISA $OUT/exit.elf
OK
exit=0
$ spike -l --log-commits --isa=$ISA $OUT/exit.elf 2>&1 | head -12
core   0: 0x0000000000001000 (0x00000297) auipc   t0, 0x0
core   0: 3 0x0000000000001000 (0x00000297) x5  0x0000000000001000
core   0: 0x0000000000001004 (0x02028593) addi    a1, t0, 32
core   0: 3 0x0000000000001004 (0x02028593) x11 0x0000000000001020
core   0: 0x0000000000001008 (0xf1402573) csrr    a0, mhartid
core   0: 3 0x0000000000001008 (0xf1402573) x10 0x0000000000000000
core   0: 0x000000000000100c (0x0182b283) ld      t0, 24(t0)
core   0: 3 0x000000000000100c (0x0182b283) x5  0x0000000080000000 mem 0x0000000000001018
core   0: 0x0000000000001010 (0x00028067) jr      t0
core   0: 3 0x0000000000001010 (0x00028067)
core   0: >>>>  $xrv64i2p1_m2p0_a2p1_f2p2_d2p2_zicond1p0_zicsr2p0_zifencei2p0_zmmul1p0_zfh1p0_zfhmin1p0_zba1p0_zbb1p0_zbs1p0
core   0: 0x0000000080000000 (0x00600513) li      a0, 6
```

The first five instructions are Spike's boot ROM at `0x1000`. The `>>>>` line is the symbol
`$x<isa>` (an ELF mapping symbol) that marks where our code starts.

### 2. A custom-instruction plugin

`kmtest.cc` implements `kmt.add1 rd, rs1, rs2` (rd = rs1 + rs2 + 1) and `kmt.mix`, in custom-0,
with the same encodings as the [riscv-opcodes](riscv-opcodes.md) and
[`.insn`](binutils-insn.md) examples (`MATCH 0x0000000b` and `0x0200000b`, `MASK 0xfe00707f`). The
core of it:

```cpp
#include "extension.h"
#include "processor.h"
#include "disasm.h"

template <bool logged>
static void write_rd(processor_t *p, insn_t insn, reg_t v) {
  if (logged) p->get_state()->log_reg_write[insn.rd() << 4] = {v, 0};  // for --log-commits
  p->get_state()->XPR.write(insn.rd(), v);
}
template <bool logged>
static reg_t kmt_add1(processor_t *p, insn_t insn, reg_t pc) {
  auto &x = p->get_state()->XPR;
  write_rd<logged>(p, insn, x[insn.rs1()] + x[insn.rs2()] + 1);
  return pc + 4;
}
// ... kmt_mix likewise ...
class kmtest_t : public extension_t {
 public:
  const char *name() const override { return "kmtest"; }
  std::vector<insn_desc_t> get_instructions(const processor_t &) override {
    auto a = kmt_add1<false>, al = kmt_add1<true>;   // fast and logged variants
    auto m = kmt_mix<false>,  ml = kmt_mix<true>;
    return {{0x0000000b, 0xfe00707f, a, a, a, a, al, al, al, al},
            {0x0200000b, 0xfe00707f, m, m, m, m, ml, ml, ml, ml}};
  }
  std::vector<disasm_insn_t *> get_disasms(const processor_t *) override {
    return {new disasm_insn_t("kmt.add1", 0x0000000b, 0xfe00707f, {&k_rd, &k_rs1, &k_rs2}),
            new disasm_insn_t("kmt.mix",  0x0200000b, 0xfe00707f, {&k_rd, &k_rs1, &k_rs2})};
  }
};
REGISTER_EXTENSION(kmtest, []() { static kmtest_t ext; return &ext; })
```

The test program `xkmtest.S` uses the `.insn` macro `kmt.add1 a3, a1, a2` with a1 = 40 and a2 = 1,
and exits with 0 if a3 = 42.

```
$ g++ -std=c++20 -O2 -fPIC -shared -I/opt/riscv/include -I/opt/riscv/include/riscv \
    -I/opt/riscv/include/softfloat $E/spike/kmtest.cc -o $OUT/libkmtest.so
exit=0
$ riscv64-unknown-elf-gcc -march=$ISA -mabi=lp64d -nostdlib -nostartfiles -static \
    -T $E/baremetal/link.ld -Wa,-I$E/baremetal -Wa,-I$E/asm -o $OUT/xkmtest.elf $E/baremetal/xkmtest.S
$ spike --extlib=$OUT/libkmtest.so --isa=${ISA}_xkmtest $OUT/xkmtest.elf
exit=0
$ spike -l --log-commits --extlib=$OUT/libkmtest.so --isa=${ISA}_xkmtest $OUT/xkmtest.elf 2>&1 | grep -A8 ">>>>"
core   0: >>>>  $xrv64i2p1_m2p0_a2p1_f2p2_d2p2_zicond1p0_zicsr2p0_zifencei2p0_zmmul1p0_zfh1p0_zfhmin1p0_zba1p0_zbb1p0_zbs1p0
core   0: 0x0000000080000000 (0x02800593) li      a1, 40
core   0: 3 0x0000000080000000 (0x02800593) x11 0x0000000000000028
core   0: 0x0000000080000004 (0x00100613) li      a2, 1
core   0: 3 0x0000000080000004 (0x00100613) x12 0x0000000000000001
core   0: 0x0000000080000008 (0x00c5868b) kmt.add1 a3, a1, a2
core   0: 3 0x0000000080000008 (0x00c5868b) x13 0x000000000000002a
core   0: 0x000000008000000c (0x02a00293) li      t0, 42
core   0: 3 0x000000008000000c (0x02a00293) x5  0x000000000000002a
```

Without the plugin, the same word is an illegal instruction:

```
$ spike --instructions=30 -l --isa=$ISA $OUT/xkmtest.elf 2>&1 | sed -n 7,11p
core   0: 0x0000000080000000 (0x02800593) li      a1, 40
core   0: 0x0000000080000004 (0x00100613) li      a2, 1
core   0: 0x0000000080000008 (0x00c5868b) unknown
core   0: exception trap_illegal_instruction, epc 0x0000000080000008
core   0:           tval 0x0000000000c5868b
```

With `_xkmtest` in the ISA string but no `--extlib`, Spike falls back to loading
`libcustomext.so` and aborts:

```
$ spike --isa=${ISA}_xkmtest $OUT/xkmtest.elf
terminate called after throwing an instance of 'std::runtime_error'
  what():  Plugin "imsic_mmio" already registered
exit=255
```

`--extension=kmtest` (with `--extlib`, without `_xkmtest` in the ISA string) also works.

### 3. pk

```
$ riscv64-unknown-elf-gcc -march=$ISA -mabi=lp64d -nostdlib -nostartfiles -static \
    -o $OUT/pk-hello.elf $E/spike/pk-hello.S
$ spike pk $OUT/pk-hello.elf
hello from pk!
exit=7
```

`pk-hello.S` calls `write(1, msg, 15)` and `exit(7)` with `ecall`. The container's GCC ships
picolibc, not newlib. So for pk programs either use raw system calls like this, or check that a
picolibc build talks to pk correctly before relying on `printf`.

## Limitations and gotchas

- No SIMT: no warps, masks, shared PC or barriers. With `-p<n>`, harts run 5,000 instructions each
  in turn.
- `decode_macros.h` (`RS1`, `WRITE_RD`, ...) is not installed. Plugins use the `state_t` API and
  must fill `log_reg_write` themselves in the logged variant, or the commit log misses the write.
- Include order: do not put `/opt/riscv/include/fesvr` on the include path. Its `syscall.h` shadows
  the system header and breaks `<atomic>`.
- Always pass `--extlib` when the ISA string names an `x` extension (see the abort above).
- 48-bit instructions are illegal unless Zca is enabled
  ([riscv-isa-sim@4c6a9bc `riscv/processor.cc`, lines 720 and 721](https://github.com/riscv-software-src/riscv-isa-sim/blob/4c6a9bc79dab80616932949707e7c0471d8e9e54/riscv/processor.cc#L720-L721));
  64-bit ones decode.
- `--instructions=N` ends with exit status 0 even if the program trapped. Check the log.
- Spike's C++ API is not stable. The image pins the commit for that reason.
- Memory behaviour between harts is sequentially consistent. Never use Spike as a memory-model
  oracle.

## How Kamui uses it

- **Early runs of Xkm programs.** A Spike plugin `libxkm.so` can be generated from
  `encodings/generated/encoding.out.h` (see [riscv-opcodes.md](riscv-opcodes.md)) for the lane-local
  Xkm instructions (Xkmmufu, Xkmmisc, CSR reads with fixed values). This lets hand-written programs
  run before the Kamui simulator exists. Warp-level instructions cannot be modelled in a plugin.
- **Model for the functional simulator.** Spike's structure (match/mask decode table, per-hart state
  object, commit log) is the model for the lane core of the Kamui C++ functional simulator.
- **Third reference for scalar code.** For scalar RV64 code (all base instructions), run the same
  program on Spike, Sail and the simulator and diff the commit logs.
- **Lockstep trace format.** A candidate format for the conformance runner is Spike's commit line
  with `core` replaced by `warp:lane`.

## References

- <https://github.com/riscv-software-src/riscv-isa-sim> README ("Simulating a New Instruction",
  "Interactive Debug Mode").
- Plugin examples at riscv-isa-sim@4c6a9bc:
  [`customext/cflush.cc`](https://github.com/riscv-software-src/riscv-isa-sim/blob/4c6a9bc79dab80616932949707e7c0471d8e9e54/customext/cflush.cc),
  [`customext/dummy_rocc.cc`](https://github.com/riscv-software-src/riscv-isa-sim/blob/4c6a9bc79dab80616932949707e7c0471d8e9e54/customext/dummy_rocc.cc),
  [`ci-tests/custom-csr.cc`](https://github.com/riscv-software-src/riscv-isa-sim/blob/4c6a9bc79dab80616932949707e7c0471d8e9e54/ci-tests/custom-csr.cc)
  (plugin with a CSR),
  [`ci-tests/testlib.cc`](https://github.com/riscv-software-src/riscv-isa-sim/blob/4c6a9bc79dab80616932949707e7c0471d8e9e54/ci-tests/testlib.cc)
  (Spike as a library).
- <https://github.com/riscv-software-src/riscv-pk>.

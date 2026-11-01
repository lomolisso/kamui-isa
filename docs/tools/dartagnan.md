# Dartagnan (Dat3M)

## What it is

Dartagnan is a bounded model checker for concurrent programs under weak memory models.
You give it a memory model (a `.cat` file) and a program (here: a litmus test). It
encodes every execution of the program and the model as one SMT formula and asks Z3
whether an execution satisfying the test's condition exists. For kamui-isa it is the
**main oracle for PTX litmus verdicts**: it ships formal PTX models (`ptx-v6.0.cat`,
`ptx-v7.5.cat`) and a PTX litmus parser, which no other maintained tool has.
Memory-model vocabulary (litmus test, morally strong, scope, proxy) is explained in the
[glossary](../glossary.md).

## Where it runs

Dev container only (no GPU needed; see [devcontainer.md](devcontainer.md)). It is a
Java 17 program; one litmus test takes about 1 s including JVM start-up.

## Version pinned

| Item | Value |
|---|---|
| Release in the image | Dat3M **4.4.1**, built from tag `4.4.1` (`ARG DAT3M_TAG=4.4.1` in the dev container Dockerfile) |
| Install path | `/opt/dat3m` (the full 4.4.1 source tree: `cat/`, `litmus/`, `dartagnan/src/`); `DAT3M_HOME=/opt/dat3m`; models in `/opt/dat3m/cat/` |
| Wrapper | `dartagnan` on `PATH` = `java -jar $DAT3M_HOME/dartagnan/target/dartagnan.jar` |
| Solver | Z3 through JavaSMT (bundled) |
| Upstream source | https://github.com/hernanponcedeleon/Dat3M. Some file and line references below are to master at commit [`b81ec6c`](https://github.com/hernanponcedeleon/Dat3M/tree/b81ec6c55503e824bb0ddc4ebac6c6f0a63d56d8) (2026-09-24), which is newer than 4.4.1. Record 4.4.1 in results. |

Cat files present in the 4.4.1 image (`ls /opt/dat3m/cat/`):
`aarch64 arm c11-orig c11-partialsc c11 imm linux-kernel lock opencl-herd opencl power
ppcfences ptx-v6.0 ptx-v7.5 rc11 riscv-orig riscv riscvfences sc stdlib svcomp tso vmm
vulkan-nochains vulkan x86fences`.

## Commands we use

```bash
# one PTX litmus test against the PTX 7.5 model (proxies), recommended flags
dartagnan /opt/dat3m/cat/ptx-v7.5.cat --target=ptx --method=eager --property=program_spec test.litmus

# same test against the PTX 6.0 model (no proxies; closest to the ASPLOS 2019 Alloy model)
dartagnan /opt/dat3m/cat/ptx-v6.0.cat --target=ptx --method=eager --property=program_spec test.litmus

# RISC-V litmus test against RVWMO, to cross-check herd7
dartagnan /opt/dat3m/cat/riscv.cat --target=riscv --property=program_spec test.litmus

# tests with loops: raise the unrolling bound (default 1)
dartagnan /opt/dat3m/cat/ptx-v7.5.cat --target=ptx --method=eager --bound=3 spinlock.litmus

# all options
dartagnan --help
```

Flags explained:

- `--target=ptx` tells Dartagnan which instruction set the program is in, so it can lower
  architecture events (here only PTX `atom` and `red`, which become a load/store pair,
  `/opt/dat3m/dartagnan/src/main/java/com/dat3m/dartagnan/program/processing/compilation/VisitorPTX.java`).
  For `.litmus` files it is optional (the header word `PTX` sets it). It must match the cat
  file; Dartagnan does not check that.
- `--method=eager` builds one monolithic SMT query. The default `lazy` method uses a
  custom theory solver (CAAT) and is faster, but Dat3M's own PTX v7.5 unit test disables it
  because "Some of these give wrong results. See #1039"
  ([`LitmusPTXv7_5Test.java` line 28 at `b81ec6c`](https://github.com/hernanponcedeleon/Dat3M/blob/b81ec6c55503e824bb0ddc4ebac6c6f0a63d56d8/dartagnan/src/test/java/com/dat3m/dartagnan/litmus/LitmusPTXv7_5Test.java#L28),
  issue https://github.com/hernanponcedeleon/Dat3M/issues/1039).
  We reproduced a disagreement (example D8 below). **Always use `--method=eager` for PTX.**
- `--property=program_spec` checks only the litmus condition. Without it Dartagnan prints
  a warning that the default properties are of mixed type and falls back to
  `program_spec` anyway.
- `--bound=N` unrolls every loop N times. If an execution could need more iterations the
  result is `UNKNOWN`.

## Input formats

### PTX litmus (Dat3M dialect)

Grammar: `/opt/dat3m/dartagnan/src/main/antlr4/LitmusPTX.g4` (the full list of supported
instructions). Example (our test
[MP+rel.gpu+acq.gpu.litmus](../examples/memory-model/ptx/MP+rel.gpu+acq.gpu.litmus)):

```
PTX MP+rel.gpu+acq.gpu
"Message passing across CTAs with gpu-scope release/acquire. Stale data is forbidden."
{
x=0;
y=0;
P1:r0=0;
P1:r1=0;
}
 P0@cta 0,gpu 0         | P1@cta 1,gpu 0         ;
 st.weak x, 1           | ld.acquire.gpu r0, y   ;
 st.release.gpu y, 1    | ld.weak r1, x          ;
exists
(P1:r0 == 1 /\ P1:r1 == 0)
```

- Line 1: `PTX` plus the test name. Line 2: optional quoted comment.
- `{ ... }`: initial values of locations and registers (`P1:r0=0`), plus optional proxy
  declarations `t@texture aliases x;`.
- Thread header: `P<i>@cta <c>,gpu <g>` places each thread in the scope tree. Two threads
  with equal `cta` are in the same CTA. There is no cluster id.
- Instructions: `ld.<sem>[.<scope>] rN, loc`, `st.<sem>[.<scope>] loc, v`,
  `atom.<sem>.<scope>.<op> rN, loc, v`, `red.<sem>.<scope>.<op> loc, v`,
  `fence.{sc,acq_rel}.<scope>`, `fence.proxy.<kind>`, `fence.proxy.alias`,
  `bar.cta.sync <n>`, branches `bne r, v, LC01` and labels `LC01:`. No `.global`, no
  `.u32`, no brackets around addresses.
- Condition: `exists (...)`, `~exists (...)`, or `forall (...)` over `P<i>:rN` and
  locations, with `/\` (and), `\/` (or), `==`, `!=`.

### RISC-V litmus

Standard herd syntax ([herd7-litmus7.md](herd7-litmus7.md)). Dartagnan reads the same files.

### Cat models

Dat3M's cat dialect is close to herd7's but adds base relations herd7 does not have, e.g.
`sr` (same scope), `scta` (same CTA), `vloc` (same virtual address), `syncbar`,
`sync_fence`, and tags like `GEN`, `ALIAS`, `CTA`. So `ptx-v7.5.cat` does **not** run in
herd7, and herd7's `riscv.cat` and Dat3M's `riscv.cat` are separate files.

## Output formats

```
Test: ptx/MP+rel.gpu+acq.gpu.litmus
Result: FAIL
Reason: Program specification violation found
Condition: exists (1:r0 == bv64(1)) && (1:r1 == bv64(0))
Time: 0.436 secs
```

`Result:` is one of `PASS`, `FAIL`, `UNKNOWN`, or `ERROR`. **What PASS means depends on
the quantifier** (upstream at `b81ec6c`:
[`Property.java` lines 42 to 48](https://github.com/hernanponcedeleon/Dat3M/blob/b81ec6c55503e824bb0ddc4ebac6c6f0a63d56d8/dartagnan/src/main/java/com/dat3m/dartagnan/configuration/Property.java#L42-L48),
[`ModelChecker.java` lines 111 to 115](https://github.com/hernanponcedeleon/Dat3M/blob/b81ec6c55503e824bb0ddc4ebac6c6f0a63d56d8/dartagnan/src/main/java/com/dat3m/dartagnan/verification/solving/ModelChecker.java#L111-L115)):

| Condition | `PASS` means | `FAIL` means | Our verdict for the condition's outcome |
|---|---|---|---|
| `exists C` | an execution satisfying C was found (reachable) | no execution satisfies C | PASS = **allowed**, FAIL = **forbidden** |
| `~exists C` | no execution satisfies C | one was found | PASS = **forbidden**, FAIL = **allowed** |
| `forall C` | every execution satisfies C | some execution violates C | PASS = "not C" is **forbidden** |

`UNKNOWN`: no witness found but some loop was not fully unrolled; raise `--bound`.
`ERROR`: parse error or unsupported feature (the reason is printed).

The unit-test expectation files (for example
`/opt/dat3m/dartagnan/src/test/resources/PTXv7_5-expected.csv`) encode PASS as `1` and
FAIL as `0`
([`ResourceHelper.java` line 41 at `b81ec6c`](https://github.com/hernanponcedeleon/Dat3M/blob/b81ec6c55503e824bb0ddc4ebac6c6f0a63d56d8/dartagnan/src/test/java/com/dat3m/dartagnan/test/ResourceHelper.java#L41)).
In `tests/litmus/expected.csv` we store the **verdict** (allowed or forbidden for the
outcome named in the condition), never the raw PASS/FAIL, to remove this ambiguity.

## Worked example

Run on 2026-10-30 in `kamui-isa-dev:0.2` (Dat3M 4.4.1, OpenJDK 17.0.20.1; D1 re-run
through `tools/dev.sh` on 2026-10-31 with the command below, same result). The inputs
are in [docs/examples/memory-model/ptx/](../examples/memory-model/ptx/): the gpu test
shown above and the same test with `.cta` in place of `.gpu`. From the repository root:

```bash
tools/dev.sh 'cd docs/examples/memory-model && dartagnan $DAT3M_HOME/cat/ptx-v7.5.cat --target=ptx ptx/MP+rel.gpu+acq.gpu.litmus'
```

**D1: gpu-scope MP, expected forbidden.** Output (the mixed-properties warning is omitted
in later examples):

```
[30.10.2026] 03:06:44 [WARN] PropertyEncoder.encodeProperties - The set of properties [Program specification, Termination, CAT specification] are of mixed type (safety and reachability properties). Cannot encode mixed properties into a single SMT-query. You can select a different set of properties with option --property. Defaulting to program_spec.
Test: ptx/MP+rel.gpu+acq.gpu.litmus
Result: FAIL
Reason: Program specification violation found
Condition: exists (1:r0 == bv64(1)) && (1:r1 == bv64(0))
Time: 0.436 secs
[time] real 0.962s
```

`exists` plus `FAIL` = the stale read is **forbidden**: the release and acquire are
morally strong (both `.gpu`, both threads on GPU 0), so they synchronize.

**D2: cta-scope MP across CTAs, expected allowed**
([MP+rel.cta+acq.cta.litmus](../examples/memory-model/ptx/MP+rel.cta+acq.cta.litmus)).

```
Test: ptx/MP+rel.cta+acq.cta.litmus
Result: PASS
Time: 0.406 secs
[time] real 0.898s
```

`exists` plus `PASS` = **allowed**: each `.cta` scope excludes the other thread (CTA 0 vs
CTA 1), so the pair is not morally strong and nothing synchronizes.

**D3 to D7** (same tool, more cases; `Manual/` and `Nvidia/` are under
`/opt/dat3m/litmus/PTX/`, the RISC-V tests under
[docs/examples/memory-model/riscv/](../examples/memory-model/riscv/)):

| Id | Command (short) | Result | Time (wall) | Meaning |
|---|---|---|---|---|
| D3 | D1 and D2 with `--method=eager` | FAIL / PASS | 0.87 s / 0.89 s | same verdicts |
| D4 | D1 and D2 with `ptx-v6.0.cat` | FAIL / PASS | 0.94 s / 0.87 s | v6.0 agrees |
| D5 | `litmus/PTX/Manual/MP-cta-gpu.litmus` (`~exists`) | PASS | 0.95 s | `~exists` + PASS = forbidden |
| D5 | `litmus/PTX/Nvidia/proxy/Proxy-MP-Alias+diffProxy-noFence.litmus` | PASS | 0.95 s | allowed: alias without proxy fence |
| D6 | RISC-V `MP+fence.w.w+fence.r.r.litmus` with `riscv.cat` | FAIL | 0.90 s | forbidden, agrees with herd7 |
| D6 | RISC-V `MP.litmus` with `riscv.cat` | PASS | 1.06 s | allowed, agrees with herd7 |
| D7 | D1 with `.gpu` replaced by `.cluster` | ERROR | 0.42 s | `Line 10:37 mismatched input 'cluster' expecting {'cta', 'gpu', 'sys'}` |

**D8: batch over the Dat3M `Manual` corpus**: all 100 files in `litmus/PTX/Manual/` and
`Manual/proxy/`, `ptx-v7.5.cat`, `--method=eager`, one JVM per test. This run used the
test files of Dat3M master at `b81ec6c`; the 4.4.1 copy in `/opt/dat3m/litmus/PTX/Manual/`
has the same 100 files. Result: **91 s wall** in total, 81 PASS, 18 FAIL, 1 UNKNOWN
(`MICRO24-Fig4b-correct.litmus`, which has a spin loop and says in its own header that
UNKNOWN is the expected answer at bound 1). All 99 tests that appear in Dat3M's
`PTXv7_5-expected.csv` matched. The loop (inside the dev container, from the repository
root):

```bash
OUT=$PWD/build/dat3m-manual-eager.csv
cd /opt/dat3m && for f in litmus/PTX/Manual/*.litmus litmus/PTX/Manual/proxy/*.litmus; do
  r=$(dartagnan cat/ptx-v7.5.cat --target=ptx --method=eager --property=program_spec $f 2>&1 \
      | grep -E '^Result:' | awk '{print $2}')
  echo "$f,$r"
done > "$OUT"
```

Running the same 100 tests with the default `lazy` method (the same loop without
`--method=eager`) gave two different answers:

```
< litmus/PTX/Manual/proxy/Proxy-Const-MP-cause1.litmus,PASS     (eager, matches expected)
< litmus/PTX/Manual/proxy/Proxy-Const-MP-cause2.litmus,PASS
> litmus/PTX/Manual/proxy/Proxy-Const-MP-cause1.litmus,FAIL     (lazy, wrong)
> litmus/PTX/Manual/proxy/Proxy-Const-MP-cause2.litmus,FAIL
```

This is the issue #1039 behaviour and the reason for `--method=eager`.

## How kamui-isa uses it

### The PTX litmus suite

The suite lives in [tests/litmus/](../../tests/litmus/README.md): the 265 Dat3M safety tests and the expanded
NVlabs/mixedproxy tests, every condition rewritten as an `exists` condition, and `tests/litmus/expected.csv`
with one verdict (allowed or forbidden) per test and model. `tools/litmus/run_formal.py` runs Dartagnan exactly
as Dat3M's unit tests do (`--method=eager --bound=1 --solver=z3`), about 35 s for the whole suite on 32 cores
of the build host. The README explains the layout, the columns and every known disagreement.

### Full `Xkmscope` (tier 2)

If the Kamui memory model is written as a `.cat` file over RISC-V events with scope tags,
Dartagnan can check the lowered tests (`tests/litmus/kamui/`) against it, and the
acceptance check is "every forbidden PTX outcome is forbidden for the lowered test".
Adding a scope tag for cluster requires changing the Java parser in a fork
(`LitmusPTX.g4` and `Tag.java`), not just a cat file.

## Limitations

- **No sm_90 features**: no `.cluster`, no async proxy, no `mbarrier`, no `fence.acquire`/
  `.release`, no `.volatile`, no `.mmio`. The newest formal PTX model available is
  PTX 7.5.
- **Bounded**: loops are unrolled to `--bound`; results with loops can be `UNKNOWN`.
- **Lazy method is unreliable for PTX v7.5** (#1039); use `--method=eager`.
- **PASS/FAIL depend on the quantifier**; always convert to allowed/forbidden.
- **Version skew**: upstream master is newer than the 4.4.1 in the image. If a test
  parses on master but not in 4.4.1 (or the reverse), record it.
- Each run starts a JVM (about 0.5 s overhead). For hundreds of tests, run them in
  parallel (`xargs -P`) or use Dat3M's unit-test runner.

## References

- Repository and README: <https://github.com/hernanponcedeleon/Dat3M>, `/opt/dat3m/README.md`
  in the dev container
- Tong et al., "Towards Unified Analysis of GPU Consistency", ASPLOS 2024
- Haas et al., "CAAT: Consistency as a Theory", OOPSLA 2022 (the lazy method)
- [glossary](../glossary.md), [herd7-litmus7.md](herd7-litmus7.md), [alloy.md](alloy.md)

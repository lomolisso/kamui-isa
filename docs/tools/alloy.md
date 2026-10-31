# Alloy

## What it is

Alloy is a language and a tool for relational modelling (Daniel Jackson, MIT). You
describe sets ("signatures"), relations between them ("fields"), constraints ("facts"),
and questions ("run" asks for an example, "check" asks for a counterexample). The Alloy
Analyzer translates everything, up to a size bound called the **scope** (for example
"at most 6 events"), into a SAT problem via Kodkod and solves it.

For memory models, signatures are events, threads and scopes; fields are `po`, `rf`,
`co`; facts are the model's axioms. "Is this litmus outcome allowed?" becomes "run: find
an execution with this shape that satisfies the axioms". "Is this compiler mapping
correct?" becomes "check: is there a target execution that maps back to an illegal source
execution?" (Lustig et al., ASPLOS 2019; the paper is
[`deps/ptx-memory-model/PTXMemoryModelASPLOS2019.pdf`](../../deps/ptx-memory-model/PTXMemoryModelASPLOS2019.pdf)).
Words such as litmus test, `rf`, `co` and scope are explained in the
[glossary](../glossary.md).

For kamui-isa, Alloy matters for two models and one future use:

| Model | Location | PTX version | Front end |
|---|---|---|---|
| ASPLOS 2019 PTX model (+ scoped RC11 + mapping) | [`deps/ptx-memory-model/`](../../deps/ptx-memory-model/) `{ptx,src11,compile_src11_ptx,util}.als` | 6.0 | none; you write queries by hand |
| ISCA 2022 mixed-proxy model | `alloy/ptx.als` in https://github.com/NVlabs/mixedproxy (not a submodule; tested at commit `0807da2`) | 7.5 | Python `src/test_to_alloy.py` converts `.test` litmus files |
| Future: PTX to Kamui mapping check | to be written, in the style of `compile_src11_ptx.als` | 8.7 subset | none |

## Where it runs

Dev container, headless (no GUI needed). Java 17. See [devcontainer.md](devcontainer.md).

## Version pinned

| Item | Value |
|---|---|
| Alloy in the image | **6.2.0**, `/opt/alloy/alloy-6.2.0/` with launcher `bin/alloy` (CLI) and `bin/alloy-gui`; jar `/opt/alloy/alloy-6.2.0/lib/app/org.alloytools.alloy.dist.jar` |
| Alloy for the 2019 artifact | **4.2** (lightly modified), bundled as `deps/ptx-memory-model/alloy4.2.jar` |
| Alloy for mixedproxy | **5.1.0**, the version its `Makefile` fetches from https://github.com/AlloyTools/org.alloytools.alloy/releases/download/v5.1.0/org.alloytools.alloy.dist.jar (sha256 `a3b43e8ec9967947aea2d5101bd96b3c4eb0d81eb3dc9bba41cc9649349c690a`) |
| Java | OpenJDK 17.0.20 in the image (`javac` included) |

### Compatibility of the old models with Alloy 6 (measured)

- **2019 model, unmodified, fails in Alloy 6** with a syntax error in `util.als`:
  `Syntax error in util.als at line 8 column 3`. The cause is the variable name `e'` in
  `pred total` (`deps/ptx-memory-model/util.als:8`): in Alloy 6 the prime `'` is the
  temporal "next state" operator, so `e'` is no longer an identifier. Renaming `e'` to
  `e2` in a copy is the only change needed; after that Alloy 6.2.0 parses all four files
  and gives the same answers as Alloy 4.2 (examples A1, A3, A4 below). The `open util`
  line before `module ptx` is accepted by both versions.
- **The artifact's Java wrapper `RunAlloy.java` does not compile against Alloy 5 or 6**:
  the API packages were renamed (`edu.mit.csail.sdg.alloy4compiler.*` became
  `edu.mit.csail.sdg.parser`, `edu.mit.csail.sdg.translator`, ...). Use it only with the
  bundled `alloy4.2.jar`, which works under Java 17 (javac prints only deprecation notes).
- **mixedproxy's `alloy/ptx.als` loads in Alloy 6 unchanged** (its default command is SAT).
  Its `RunAlloy.java` targets the Alloy 5 API, so its Python driver is run with Alloy 5.1.0.

Recommendation: use **Alloy 6.2.0 CLI** for new work and for the 2019 model (with the
one-line `util.als` fix in a copy under `build/`, or in the litmus suite once it has an
Alloy directory), and **Alloy 5.1.0** only to run mixedproxy's Python front end.

## Commands we use

```bash
A6=/opt/alloy/alloy-6.2.0/bin/alloy

# run every command in a model; one line per command with SAT/UNSAT
$A6 exec -f -o out/ model.als

# run one command, write instances as text (default output is receipt.json only)
$A6 exec -f -c MP_cta -t text -o out/ model.als
#   -c <name|index|wildcard>  which command; -o <dir> output dir; -f overwrite it
#   -t text                   also write <cmd>-solution-<n>.txt per instance

# the 2019 artifact with its own Alloy 4.2 (prints XML instances to stdout).
# Copy the jar first, never run it in place (see Limitations).
mkdir -p build/alloy/a42 && cp deps/ptx-memory-model/RunAlloy.java deps/ptx-memory-model/alloy4.2.jar build/alloy/a42/
(cd build/alloy/a42 && javac -nowarn -cp alloy4.2.jar RunAlloy.java)
java -cp build/alloy/a42:build/alloy/a42/alloy4.2.jar RunAlloy -f <file.als> [-b <bound>] [-n <max instances>] <command>...

# mixedproxy litmus front end (Alloy 5.1.0 jar in its alloy/ directory, lark-parser on PYTHONPATH)
python3 src/test_to_alloy.py tests/SB_cta.test
```

Run all of these inside the dev container (`tools/dev.sh`) and write outputs under
`build/`. `deps/` is read-only reference material. On the machine where you edit,
`build/` is only a mount point, so files must be created from inside the container.

## Input formats

### `.als` (Alloy)

The 2019 PTX model in short (`deps/ptx-memory-model/ptx.als`):

```
sig Scope { subscope: set Scope }                 // scope tree, line 19
sig Thread extends Scope { start: one Event }     // threads are the leaves, line 22
abstract sig Event { po: lone Event, scope: one Scope }        // line 24
sig Read extends MemoryEvent { rmw: lone Write, dep: set Event }
sig Write extends MemoryEvent { rf: set Read, co: set Write }
sig Acquire extends Read {}  sig Release extends Write {}      // lines 138-139
pred ptx_mm { no_thin_air and location_sc and atomicity and coherence and causality } // line 76
```

A litmus test is written as an Alloy module that opens `ptx`, declares exactly the events
of the test as `one sig`s, pins every relation in a fact, and asks a `run` question.
Our example [mp_litmus.als](../examples/memory-model/alloy2019/mp_litmus.als)
(comments shortened):

```
module mp_litmus
open ptx

one sig Sys, Gpu, Cta0, Cta1 extends Scope {}
one sig T0, T1 extends Thread {}
one sig X, Y extends Address {}
one sig Wx extends Write {}
one sig Wy extends Release {}
one sig Ry extends Acquire {}
one sig Rx extends Read {}

fact shape {
  Event = Wx + Wy + Ry + Rx                       // nothing else exists
  Scope = Sys + Gpu + Cta0 + Cta1 + T0 + T1
  Address = X + Y
  subscope = Sys->Gpu + Gpu->Cta0 + Gpu->Cta1 + Cta0->T0 + Cta1->T1
  start = T0->Wx + T1->Ry
  po = Wx->Wy + Ry->Rx
  address = Wx->X + Rx->X + Wy->Y + Ry->Y
  Wx.scope = T0                                   // weak accesses: scope = own thread
  Rx.scope = T1
  no dep
  no rmw
}

// Ry reads Wy, Rx reads the initial value of x
pred outcome { Ry in Wy.rf and no rf.Rx }

run MP_gpu { ptx_mm and outcome and Wy.scope = Gpu and Ry.scope = Gpu } for 6
run MP_cta { ptx_mm and outcome and Wy.scope = Cta0 and Ry.scope = Cta1 } for 6
```

`open ptx` looks for `ptx.als` (and through it `util.als`) in the same directory as
`mp_litmus.als`. The model files are third-party and stay in
[`deps/ptx-memory-model/`](../../deps/ptx-memory-model/); the worked example copies them
next to the query under `build/`.

Because the scope tree is data (`subscope`), a `.cluster` level is just another node
between `Cta0` and `Gpu`; the axioms do not change. This is the cheapest way to get a
formal (if unofficial) answer for cluster-scope litmus tests.

### mixedproxy `.test` format

Grammar: `src/grammar.lark` in the mixedproxy repository. Example (`tests/SB_cta.test`):

```
.global x;
.global y;

d0.b0.t0 {            <- device 0, block 0, thread 0
  st [x], 1;
  fence.sc.cta;
  ld r0, [y];
}

d0.b0.t1 {
  st [y], 2;
  fence.sc.cta;
  ld r1, [x];
}

assert (r0 == 2 || r1 == 1) as my_test;
```

Closer to real PTX than Dat3M's dialect (brackets, `.global`, `.volatile`), with
`permit(...)` (the condition must be reachable) and `assert(...)` (it must hold in every
execution). Scopes are only `cta`, `gpu`, `sys`; proxies are generic, texture, surface,
constant and virtual aliases. Tests can be templates with `$0`...`$6` placeholders and a
table after `$$`. Only 11 tests ship with it; Dat3M's `litmus/PTX/Nvidia/` (in the dev
container at `/opt/dat3m/litmus/PTX/Nvidia/`) contains expanded translations of them.

## Output formats

**Alloy 6 CLI**, one line per command:

```
00. run   MP_gpu                   0       UNSAT
01. run   MP_cta                   0    1/1     SAT
```

- For a `run`: **SAT** ("instance found") means the outcome is **allowed**; **UNSAT**
  ("no instance found") means it is **forbidden** within the bound.
- For a `check`: **UNSAT** means no counterexample within the bound (the assertion
  holds up to that size); **SAT** means a counterexample was found.
- `1/1` is the number of instances written. Output directory: `receipt.json` (commands,
  signatures, solver), and with `-t text` one `<cmd>-solution-<n>.txt` per instance, listing
  every relation, e.g. `ptx/Write<:rf={Wy$0->Ry$0}`.

**RunAlloy (2019 artifact, Alloy 4.2)** prints `Command match: <name>` on stderr and on
stdout a `<command label="...">` element containing one XML `<instance>` per solution.
Zero `<instance>` elements = no instance = forbidden (for `run`) or no counterexample (for
`check`).

**mixedproxy driver**: one line per command, e.g.
`my_test: UNSAT, assertion confirmed, matches expectation` or
`check_r1: SAT, outcome permitted`.

## Worked example

Run on 2026-10-30 in `kamui-isa-dev:0.2`. Every command runs inside the dev container
(`tools/dev.sh`), starting at the repository root. `[time]` lines are wall times measured
with `time`.

Set up the working directories (the 2019 model files are copied from the submodule, never
edited in place):

```bash
mkdir -p build/alloy/alloy2019 build/alloy/a6
cp docs/examples/memory-model/alloy2019/mp_litmus.als deps/ptx-memory-model/{ptx,util}.als build/alloy/alloy2019/
cp build/alloy/alloy2019/*.als build/alloy/a6/
mkdir -p build/alloy/a42 && cp deps/ptx-memory-model/RunAlloy.java deps/ptx-memory-model/alloy4.2.jar build/alloy/a42/
(cd build/alloy/a42 && javac -nowarn -cp alloy4.2.jar RunAlloy.java)
cd build/alloy
```

**A1: MP query on the 2019 model with the bundled Alloy 4.2.**

```
$ java -cp a42:a42/alloy4.2.jar RunAlloy -f alloy2019/mp_litmus.als MP_gpu
  Command match: MP_gpu
<command label="alloy2019/mp_litmus.als:MP_gpu">
</command>
[time] real 0.395s            -> 0 instances: forbidden

$ java ... RunAlloy -f alloy2019/mp_litmus.als MP_cta
  Command match: MP_cta
[time] real 0.370s            -> 1 instance: allowed
```

Same verdicts as Dartagnan on the equivalent `.litmus` tests (D1, D2 in
[dartagnan.md](dartagnan.md)).

**A2: the artifact's mapping check** (scoped RC11 to PTX, atomicity, bound 4):

```
$ java ... RunAlloy -f ../../deps/ptx-memory-model/compile_src11_ptx.als -b 4 src11_ptx_legal_atomicity
  Command match: src11_ptx_legal_atomicity
Scope bound 4 overrides default bound of 6
[time] real 0.492s            -> 0 counterexamples
```

**A3: Alloy 6.2.0 on the unmodified 2019 files** (fails; `cd a6`, then
`/opt/alloy/alloy-6.2.0/bin/alloy exec -f -o out_all mp_litmus.als`). The error names the
copy of `util.als`, which was in `/tmp/a6/` when this was recorded:

```
[main] ERROR alloy - excuting sub command CLI:exec error Syntax error in /tmp/a6/util.als at line 8 column 3:
There are 38 possible tokens that can appear here:
! # ( * @ Int NAME NUMBER STRING String ^ after all always before disj eventually fun historically iden int let lone no none once one pred seq set some steps sum this univ { } ~
```

**A4: Alloy 6.2.0 after renaming `e'` to `e2` in the copy of `util.als`** (still in
`build/alloy/a6`; for the last command, first copy `src11.als` and
`compile_src11_ptx.als` from `deps/ptx-memory-model/` into this directory):

```
$ sed -i "s/e'/e2/g" util.als
$ /opt/alloy/alloy-6.2.0/bin/alloy exec -f -o out_all mp_litmus.als
00. run   MP_gpu                   0       UNSAT
01. run   MP_cta                   0    1/1     SAT
[time] real 1.136s

$ /opt/alloy/alloy-6.2.0/bin/alloy exec -f -c MP_cta -t text -o out_cta mp_litmus.als
00. run   MP_cta                   0    1/1     SAT
$ grep -E 'rf=|po=|scope=' out_cta/MP_cta-solution-0.txt | head -4
ptx/Scope<:subscope={Sys$0->Gpu$0, Gpu$0->Cta0$0, Gpu$0->Cta1$0, Cta0$0->T0$0, Cta1$0->T1$0}
ptx/Write<:rf={Wy$0->Ry$0}
ptx/Event<:po={Wx$0->Wy$0, Ry$0->Rx$0}
ptx/Event<:scope={Wx$0->T0$0, Wy$0->Cta0$0, Ry$0->Cta1$0, Rx$0->T1$0}

$ /opt/alloy/alloy-6.2.0/bin/alloy exec -f -c src11_ptx_legal_atomicity -o out_atom compile_src11_ptx.als
00. check src11_ptx_legal_atomicity     0       UNSAT
[time] real 1.298s            (default bound 6: no counterexample)
```

**A5: mixedproxy with Alloy 5.1.0.** Set up inside the container, in `build/alloy`:

```bash
git clone --depth 1 https://github.com/NVlabs/mixedproxy    # recorded at commit 0807da2
cd mixedproxy
curl -L -o alloy/org.alloytools.alloy.dist.jar \
  https://github.com/AlloyTools/org.alloytools.alloy/releases/download/v5.1.0/org.alloytools.alloy.dist.jar
sha256sum alloy/org.alloytools.alloy.dist.jar              # must match the value in "Version pinned"
javac -nowarn -cp alloy/org.alloytools.alloy.dist.jar alloy/RunAlloy.java
python3 -m pip install --target ../pylark lark-parser
```

```
$ PYTHONPATH=../pylark python3 src/test_to_alloy.py tests/SB_cta.test
...
Launching Alloy...
my_test: UNSAT, assertion confirmed, matches expectation
[time] real 0.695s

$ PYTHONPATH=../pylark python3 src/test_to_alloy.py tests/CoMP_volatile.test
...
check_r1: SAT, outcome permitted
[time] real 0.599s
```

## How kamui-isa uses it

- **Litmus suite**: (a) second opinion on PTX verdicts for a subset of the suite (the
  2019 model via hand-written or generated `.als` queries, mixedproxy via `.test` files),
  to catch tool bugs such as the Dartagnan lazy-solver issue
  ([dartagnan.md](dartagnan.md)); (b) the natural place to try a **cluster scope**
  (deeper scope tree, no axiom change) and to sketch an **async proxy** extension of the
  mixed-proxy model; (c) the format for the planned **PTX-to-Kamui mapping check**: copy
  the structure of `compile_src11_ptx.als` (`map` relation, `wf_map`, `compile_*`
  predicates, `reverse_map`, one `assert` per PTX axiom) with PTX as the source and the
  Kamui model as the target. Expected cost from the paper: seconds at 4 events, hours at
  5 to 6 events with scopes (paper Figure 17), so plan bounds of 4 to 5.
- **Full `Xkmscope`** (tier 2): rerun the mapping check whenever the `Xkmscope` lowering
  table changes; keep the `.als` files in the repository (proposal: `tests/litmus/alloy/`).

## Limitations

- Never run Alloy directly on `deps/ptx-memory-model/alloy4.2.jar`: the jar in `deps/`
  was once found rewritten after a run. Copy it under `build/` first (as in the commands
  above). If `git -C deps/ptx-memory-model status` shows it modified, restore it with
  `git -C deps/ptx-memory-model checkout -- alloy4.2.jar`.
- Bounded: "no instance" only means none within the scope; the 2019 paper found one
  mapping bug only with Coq because the counterexample was too large for Alloy.
- Expensive with scopes: the bound you can afford is small (4 to 6 events).
- No litmus front end for the 2019 model; you write each test as an Alloy module (a
  generator from the Dat3M dialect would be a small script).
- Neither model covers `.cluster`, the async proxy, `mbarrier`, or `fence.acquire`/`.release`.
- Version friction: 2019 model needs the `e'` fix for Alloy 6; old Java wrappers need the
  Alloy version they were written for.

## References

- Alloy: <https://alloytools.org>, releases <https://github.com/AlloyTools/org.alloytools.alloy/releases>
- Jackson, "Software Abstractions", MIT Press (the Alloy book)
- Lustig, Sahasrabuddhe, Giroux, "A Formal Analysis of the NVIDIA PTX Memory Consistency
  Model", ASPLOS 2019; artifact [`deps/ptx-memory-model`](../../deps/ptx-memory-model/)
  (https://github.com/NVlabs/PTXMemoryModel, commit `f0dc6b7`)
- Lustig, Cooksey, Giroux, "Mixed-Proxy Extensions for the NVIDIA PTX Memory Consistency
  Model", ISCA 2022, <https://github.com/NVlabs/mixedproxy>
- Wickerson et al., "Automatically Comparing Memory Consistency Models", POPL 2017 (Alloy for memory models)
- [glossary](../glossary.md), [dartagnan.md](dartagnan.md), [herd7-litmus7.md](herd7-litmus7.md)

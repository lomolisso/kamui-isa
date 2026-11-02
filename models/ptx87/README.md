# models/ptx87: the PTX ISA 8.7 memory model in Alloy

Kamui's memory contract for GPU memory is the memory consistency model of the PTX ISA 8.7 manual (chapter 8,
plus the ordering rules in the instruction descriptions). This folder holds a formal version of it in
[Alloy 6](https://alloytools.org), so that the question "may this multi-threaded program end in this state?" has
a mechanical answer, and the list of choices the formal version makes where the manual's text leaves room.

| File | What it is |
|---|---|
| `ptx87.als` | the model: events, the scope tree (system, gpu, cluster, cta, thread), proxies, state spaces, morally strong, release and acquire patterns, the orders of chapter 8 and its six axioms, CTA and cluster barriers, mbarrier objects, asynchronous operations |
| `decisions.md` | the numbered interpretation decisions `D1` to `D36`: the manual text, the alternatives, the choice, the tests that depend on it |
| `coverage.yaml` | every memory-related feature of the PTX feature catalog (`tests/corpus/catalog.yaml`) and how the model treats it |
| `compile_src11_ptx87.als`, `src11.als` | the scoped C++ (scoped RC11) to PTX 8.7 mapping check |
| `check_mapping.sh` | runs the mapping check |
| `util.als` | helpers |
| `LICENSE` | the notices of the two NVIDIA models this one is derived from |

## Where it comes from

The model starts from two published models, both by NVIDIA researchers and both BSD-licensed (see `LICENSE`):

- the PTX 6.0 model of Lustig, Sahasrabuddhe and Giroux, "A Formal Analysis of the NVIDIA PTX Memory
  Consistency Model" (ASPLOS 2019), also in `deps/ptx-memory-model`. Its scope tree has any depth, so the
  cluster level of PTX 8.x is one more node;
- the PTX 7.5 mixed-proxy model of Lustig, Cooksey and Giroux (ISCA 2022, NVlabs/mixedproxy): proxies, virtual
  aliases, proxy fences and proxy-preserved base causality order.

It then adds what PTX gained since: the `.cluster` scope and distributed shared memory, `fence.acquire` and
`fence.release`, the restricted fences (`.sync_restrict`, `.op_restrict`), `barrier.cluster`, `mbarrier` objects
with phases and transaction counts, the async proxy (bulk and tensor copies, `cp.reduce.async.bulk`, `wgmma`),
`cp.async`, `st.async`, `red.async`, the tensormap proxy, `multimem`, `griddepcontrol`, mixed-size accesses,
`.mmio`. It fixes one error of the mixed-proxy model: there, fences have no proxy, so fence-based release and
acquire patterns never synchronize (decision D1).

## How a question is asked

A litmus test (`tests/litmus/ptx/**/*.litmus`) is translated by `tools/litmus/to_alloy87.py` into an Alloy
module (`tests/litmus/alloy-ptx87/`) that opens `ptx87`, declares the test's threads, locations and events as
atoms, fixes the program (program order, addresses, scopes, values written, ...) and asks two questions:

```
run test       { ptx_mm and (outcome or undefined) } for 12 but 5 Int
run consistent { ptx_mm }                            for 12 but 5 Int
```

`test` is SAT if some execution satisfies the axioms (`ptx_mm`) and the test's condition: the outcome is
**allowed**; UNSAT means **forbidden**. `undefined` makes every outcome allowed when the program has undefined
behaviour (a mixed-size data race, an mbarrier used before its initialization, ...; decision D7). `consistent`
checks that the program has any execution at all, so that a forbidden verdict is not an accident of the
translation; a program with no execution (for example a barrier that can never complete) is reported as such.

Values are integers, so a condition such as `P1:r0 == 1 /\ P1:r1 == 0` is a condition on the values the loads
read. The bound covers every atom of the test, so the answer is exact for the test (not only up to a bound).

```bash
tools/dev.sh 'python tools/litmus/to_alloy87.py'                                   # write the queries
tools/dev.sh 'python tools/litmus/run_formal.py --models ptx-v8.7-alloy'            # all verdicts, about 8 min on 64 cores
tools/dev.sh "python tools/litmus/run_formal.py --models ptx-v8.7-alloy --tests 'ptx/kamui/ptx87/mbarrier/*'"
```

To run one query by hand, copy it next to `ptx87.als` and `util.als` and run Alloy 6.2.0 (in the dev
container):

```bash
java -Djava.library.path=/opt/alloy/alloy-6.2.0/lib/runtime/lib \
     -jar /opt/alloy/alloy-6.2.0/lib/app/org.alloytools.alloy.dist.jar exec -n -s glucose -c '*' -t text -o out q.als
```

`-t text` writes the instance (every relation of the execution) to `out/`.

## The scoped C++ mapping check

`compile_src11_ptx87.als` repeats the bounded check of the 2019 paper on this model: there is no PTX execution of
a compiled, race-free scoped C++ program (relaxed, acquire, release, `fence.{acquire,release,acq_rel,sc}`, at
any scope of the tree, the cluster level included) whose mapping back to C++ violates scoped RC11 coherence,
atomicity, SC or no-thin-air. The sanity runs `sanity`, `MP` and `MP_cluster` must find an instance (so the check
is not vacuous); the four checks must find none.

```bash
tools/dev.sh 'models/ptx87/check_mapping.sh'
```

## How it is checked

- Against the other formal models (`tools/litmus/check_suite.py`, in CI): on every test that Dartagnan's
  PTX 7.5 model, its PTX 6.0 model or the 2019 Alloy model can answer, the verdicts agree, except four barrier
  tests where the models count blocked executions differently (decision D9, explained in
  `tests/litmus/allowlist.yaml`).
- Against the hand-reasoned verdicts of `tests/litmus/manual-reasoning.yaml`.
- Against the H100 (`evidence/litmus-h100/`): no outcome the H100 produced is forbidden by the model, except the
  known mbarrier case where the H100 is weaker than the manual (the allow-list explains it; the model follows the
  manual).

The model is our reading of the manual, not NVIDIA's. Where the manual is ambiguous, `decisions.md` says so and
states the choice; a second implementation of the same decisions (in Dartagnan) is the planned cross-check.

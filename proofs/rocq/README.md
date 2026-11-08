# proofs/rocq/

A proof in [Rocq](https://rocq-prover.org) (formerly Coq) that the lowering from PTX 8.7 to Kamui
([`models/kamui/lowering.yaml`](../../models/kamui/lowering.yaml)) is correct for programs of every size: every
behaviour a lowered program has on Kamui is a behaviour PTX 8.7 allows for the original program. The bounded Alloy
check ([`models/kamui/compile_ptx87_kamui.als`](../../models/kamui/compile_ptx87_kamui.als)) covers small programs;
this proof covers all of them.

**What exactly is claimed, and where a reviewer has to look: [STATEMENT.md](STATEMENT.md).**

## Files

| Path | Contents |
|---|---|
| `Ptx87.v`, `Kamui.v`, `Lowering.v`, `Theorem.v` | the statement (the trusted files; see STATEMENT.md) |
| `STATEMENT.md` | the statement in plain words, the translation rules, the axioms |
| `proof/Embedding.v` | what the lowering keeps on each event: kinds, threads, locations, footprints, scopes |
| `proof/Derived.v` | every derived relation of the model grows under the lowering |
| `proof/Main.v` | the proofs of the statements: axioms, undefined behaviour, races, the facts of the PTX execution |
| `proof/Instances.v` | examples of the lowering and the counterexamples of the broken lowerings, checked by computation |
| `lib/Mat.v` | boolean matrices, proved against the relations they compute |
| `check/` | checkers: for each definition of `Ptx87.v` and of the lowering, a function that computes it on a finite execution, with a proof that it computes exactly that definition |
| `extract/` | the checkers extracted to OCaml, and the tools that run them on every execution Alloy finds for the litmus tests (see below) |
| `Print.v`, `statement.txt`, `assumptions.txt`, `trusted.sha256` | the printed statements and axioms that CI compares, and the checksums of the trusted files |
| `als/` | Alloy checks of the lowering that `compile_ptx87_kamui.als` does not have (standard instructions in every feature group, two more broken lowerings) |

## Build and check

```bash
git submodule update --init --depth 1 deps/hahn      # the relation library
tools/dev.sh 'make -C proofs/rocq'                    # builds hahn (once) and every file, in build/rocq
tools/dev.sh 'tools/proofs/check.sh'                  # rocqchk, axioms, statement, checksums, forbidden commands
tools/dev.sh 'proofs/rocq/als/check.sh'               # the Alloy checks of als/ (hours; see the script)
tools/dev.sh 'make -C proofs/rocq checker'            # the extracted checker, build/rocq/src/checker
tools/dev.sh 'proofs/rocq/extract/litmus.py --jobs 24'   # the checker against Alloy on the litmus tests
```

The theorems use one axiom, excluded middle (`classic`); `assumptions.txt` holds what Rocq prints. A clean build
takes about a minute (hahn another 1.5 minutes, cached in CI), `check.sh` about 20 seconds.

**How the translation is tested.** The proof is only as good as the translation of `ptx87.als` into `Ptx87.v`.
The checkers of `check/` compute every definition of `Ptx87.v` on a finite execution and are proved to compute
exactly that definition. `extract/` turns them into a program (`checker`), and `extract/litmus.py` runs it on every
execution that Alloy finds for the litmus tests (`extract/AlloyDump.java` writes them in the format of
`extract/FORMAT.md`): for each execution the checker must give Alloy's answers (each axiom, the model, undefined
behaviour, the race, and every tuple of the derived relations), and the verdict it computes must be the verdict
of `tests/litmus/expected.csv` for each of the three Alloy models.

Rocq 9.2.0 with its standard library 9.1.0, as in the dev image and in CI (the official `rocq/rocq-prover:9.2.0`
image). The relation library is [hahn](https://github.com/vafeiadis/hahn) (MIT licence), a submodule at
`deps/hahn`, pinned to commit `b33bb6c`.

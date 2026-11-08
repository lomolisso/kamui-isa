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
| `Print.v` | prints the statements and their axioms for `tools/proofs/check.sh` |
| `als/` | Alloy checks of the lowering that `compile_ptx87_kamui.als` does not have (standard instructions in every feature group, two more broken lowerings) |

## Build and check

```bash
git submodule update --init --depth 1 deps/hahn      # the relation library
tools/dev.sh 'make -C proofs/rocq'                    # builds hahn (once) and every file, in build/rocq
tools/dev.sh 'tools/proofs/check.sh'                  # rocqchk, axioms, statement, checksums, forbidden commands
tools/dev.sh 'proofs/rocq/als/check.sh'               # the Alloy checks of als/ (hours; see the script)
```

Rocq 9.2.0 with its standard library 9.1.0, as in the dev image and in CI (the official `rocq/rocq-prover:9.2.0`
image). The relation library is [hahn](https://github.com/vafeiadis/hahn) (MIT licence), a submodule at
`deps/hahn`, pinned to commit `b33bb6c`.

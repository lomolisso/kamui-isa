# The Rocq proof of the PTX 8.7 to Kamui lowering: what it states

This page is for a reviewer. It says what the proof claims, in plain words and in Rocq, and where a mistake in the
claim could hide. Everything else in `proofs/rocq/` is proof, which Rocq checks by machine.

## 1. The claim in plain words

A PTX compiler for Kamui replaces every PTX memory instruction by Kamui instructions
([`models/kamui/lowering.yaml`](../../models/kamui/lowering.yaml)). The claim: **a Kamui program obtained this way
never does anything the PTX program could not do.** More precisely, for every PTX program and every execution of
its lowering that the Kamui memory model allows, the PTX execution it corresponds to is one the PTX 8.7 memory model
allows. This holds for programs of any size and for every memory feature the models describe: loads, stores,
atomics, fences, scopes up to `.cluster`, proxies and virtual aliases, CTA and cluster barriers, mbarrier objects,
asynchronous copies, restricted fences, tensor-map proxy fences, mixed-size accesses.

The Kamui memory model *is* the PTX 8.7 model ([`Kamui.v`](Kamui.v)). So the claim reduces to: each lowering rule
either keeps the PTX events exactly, or makes the program stronger in one of two ways:

- a strong operation gets a wider scope (the standard RISC-V instructions are at `.sys`: `sw.rl` for a
  `st.release.gpu`);
- a `fence.sc.sys` is inserted before an acquire-release read-modify-write (`amoadd.w.aqrl` for an
  `atom.acq_rel.gpu.add`).

The proof shows that both keep every PTX 8.7 axiom.

What it does **not** claim: that kamui-llvm emits this lowering (its optimizations can reorder, merge or drop
operations); that hardware or a simulator follows the Kamui model; anything about the H100. The rules that work at
the level of whole instructions rather than events (`cp.async.wait_all` as commit then wait 0, the
`tensormap.cp_fenceproxy` sequence, the elect loop of K6) are checked by the litmus suite, not by this proof.

## 2. A worked example: message passing

PTX program, thread 0 in CTA 0 and thread 1 in CTA 1 of one GPU:

```
st.weak [data], 1            | ld.acquire.gpu r0, [flag]
st.release.gpu [flag], 1     | ld.weak r1, [data]
```

Its lowering with standard instructions is `sw data; sw.rl flag` and `lw.aq r0, flag; lw r1, data`. At the level of
events:

| PTX event | Kamui event | Map |
|---|---|---|
| E0 weak write of `data` (scope: thread 0) | weak write of `data` (scope: thread 0) | same |
| E1 release write of `flag`, scope GPU | release write of `flag`, **scope system** | `widen` |
| E2 acquire read of `flag`, scope GPU | acquire read of `flag`, **scope system** | `widen` |
| E3 weak read of `data` (scope: thread 1) | weak read of `data` (scope: thread 1) | same |

A Kamui execution chooses what each read reads and the order of the writes. Take the one where E2 reads E1 and E3
reads the initial `data` (`r0 == 1, r1 == 0`). The Kamui model forbids it: E1 and E2 are morally strong, so they
synchronize, and E0 precedes E3 in causality order. The theorem says nothing about it, since it is not a Kamui
execution. Take instead the execution where E2 reads the initial `flag` (`r0 == 0`). The Kamui model allows it.
Read back into the PTX program (the same reads-from and coherence order on the PTX events), it is an execution the
PTX model allows. That is what the theorem guarantees for every program and every Kamui execution.

## 3. The four trusted files

The statement is in four files. These are the only places where a mistake can make a wrong claim look proved; they
are frozen (`trusted.sha256`) after review, and any later change needs an entry in section 8 of this page.

| File | Contents | Translates |
|---|---|---|
| [`Ptx87.v`](Ptx87.v) | executions (`Exec`), every definition of the model, the axioms (`consistent`), undefined behaviour, mixed-size data races, the well-formedness facts (`wf_prog`, `wf_exec`) | [`models/ptx87/ptx87.als`](../../models/ptx87/ptx87.als) and `util.als` |
| [`Kamui.v`](Kamui.v) | the Kamui model, which is the PTX model under Kamui names (K1) | [`models/kamui/kamui.als`](../../models/kamui/kamui.als) |
| [`Lowering.v`](Lowering.v) | the map between a PTX execution and a Kamui execution (`Map`, `lowering_ex`, `lowering`), the feature groups, the broken lowerings | [`models/kamui/compile_ptx87_kamui.als`](../../models/kamui/compile_ptx87_kamui.als) |
| [`Theorem.v`](Theorem.v) | the statements, as definitions of propositions: `execution_level_statement`, `program_level_statement`, `broken_lowerings_fail` | the `assert`s of `compile_ptx87_kamui.als`, and the verdict rule of `tools/litmus/run_formal.py` |

### The statements

**Execution level** (`execution_level_statement`). For every PTX execution `P`, Kamui execution `K` and map `M`
between their events: if `P`'s program is well formed (`wf_prog P`), `K` is the lowering of `P` through `M`
(`lowering P K M`) and `K` is well formed, then

1. `P` with the execution read back from `K` is well formed (`wf_exec P`), whether or not `K` satisfies the axioms;
2. if `K` satisfies the Kamui model, `P` satisfies the PTX model;
3. if `K` has undefined behaviour (mbarrier misuse), so has `P`;
4. if `K` has a mixed-size data race, so has `P`.

**Program level** (`program_level_statement`). A program is a set of candidate executions and an outcome a set of
executions. `allowed prog out` follows the verdict rule of `tools/litmus/run_formal.py`: some execution of the
program satisfies the model and has the outcome (or undefined behaviour); or the program has a mixed-size data race
and some well-formed execution has the outcome (D38: a race frees the whole program from the axioms, but reads still
return written values). The statement: if every well-formed Kamui execution is the lowering of a PTX execution with
a matching outcome, then every outcome allowed for the Kamui program is allowed for the PTX program.

**The statement can fail** (`broken_lowerings_fail`). For each broken lowering of `compile_ptx87_kamui.als`
(an acquire lowered as relaxed, a fence narrowed to `.cta`, ...), the execution-level statement is false. This shows
that the hypotheses can hold and that the conclusion is not trivially true.

## 4. How the Alloy model became Rocq

- **Carriers.** An execution is a record over four types: events `E`, scopes `S`, addresses `A`, accesses `C`.
- **Signatures.** The signatures that extend `Event` become a kind function (`kind : E -> Kind`, 15 leaf kinds),
  so that, as Alloy's `extends` and `abstract` say, they are disjoint and every event has one. `Scope`, `CtaScope`,
  `ClusterScope`, `Thread` and `AsyncUnit` likewise (`skind`). `in` signatures (`SyncRestrictCta`, `MbarEv`, ...)
  become predicates. `Proxy` and `Space` become inductive types.
- **Fields.** A field with multiplicity `one` over a whole carrier (`scope`, `space`, `init`) and the integer
  fields become functions. Every other field becomes a relation. The typing and multiplicity that Alloy reads from
  the field declaration (`rmw: lone Write` in `sig Read`) become conjuncts of `wf_prog` or `wf_exec` named
  `decl_<field>`. An integer field of a subset signature (`val` of memory events, `ph` of mbarrier operations) is a
  total function whose value outside the subset is never used.
- **Integers.** Alloy's `Int` becomes `Z` (unbounded). `div` and `rem` truncate toward zero in Alloy, as `Z.quot`
  and `Z.rem` do. Alloy's integers are bounded by the bit width of each run, and the runs of
  `tools/litmus/run_formal.py` exclude executions with an overflow (`exec -n`); the litmus values stay far from the
  bounds.
- **Operators.** `*r` is `r＊`, `^r` is `r⁺`, `~r` is `r⁻¹`, `r.s` is `r ⨾ s`, `s <: r` is `⦗s⦘ ⨾ r`, `r :> s` is
  `r ⨾ ⦗s⦘`, `+` is `∪`, `&` is `∩`, `-` is `\` (the notations of the hahn library, `deps/hahn`). Alloy's join
  binds more tightly than `&`; the Rocq text has parentheses wherever the two differ.
- **Facts.** Each Alloy fact is split into its conjuncts, named `<fact>_<n>` in the order of the Alloy text.
  `wf_prog` has the facts about the program (what a litmus test pins); `wf_exec` the facts about the execution, the
  relations and values a run chooses: `rf`, `co`, `sc`, `bgen`, `cgen`, `synchronizes`, `val`, `ph`, `pend`,
  `expc`, `tx`. A fact may be read assuming the field multiplicities, which are facts too, so `wf_prog /\ wf_exec`
  as a whole is the conjunction of Alloy's facts.
- **Cardinality.** `#s = n` becomes `card_is s n`: `s` has exactly `n` elements.

## 5. The definitions

[`models/kamui/definitions.md`](../../models/kamui/definitions.md) lists every definition of the model with its
rule, its PTX section and its decision. Every row is a definition of `Ptx87.v` with the same name, in the same
order, with the Alloy text quoted above it. The exceptions, all of them names only:

| Alloy | Rocq | Why |
|---|---|---|
| `ptx_mm` | `consistent` | the usual name |
| `sig Thread`, `sig Read`, ... | `Thread`, `Read`, ...: predicates on `skind` and `kind` | signatures as sets |
| `Global`, `Local`, `Shared`, `Const`, `Param` | `SGlobal`, `SLocal`, `SShared`, `SConst`, `SParam` | `Global` and `Local` are Rocq keywords |
| facts | conjuncts of `wf_prog`, `wf_exec` | named `<fact>_<n>` |
| `bid.~bid` | `same_bid` | `bid` is a function, so the relation needs its domain |

## 6. The lowering compared with the Alloy check

`Lowering.v` translates `lowering_ex` of `compile_ptx87_kamui.als` predicate by predicate. It covers more:

- **Shared scopes and addresses.** The two programs have the same scope and address types; Alloy's bijections
  `sm` and `ad` become the identity. Any pair of programs related by bijections is isomorphic to such a pair.
- **Mixed-size accesses.** Allowed: each image has the access of its PTX event (`sr_acc`). The Alloy check has
  `no p/Access and no k/Access`.
- **`synchronizes` read back** (`rb_synchronizes`). In Alloy it follows from the PTX side's facts, which Alloy
  assumes; here the PTX side's facts are proved.
- **Scope widening.** `widen` may move any strong event to any enclosing scope, which covers every widening of
  `lowering.yaml` (the standard instructions are at `.sys`).
- **Every feature group.** The Alloy check tried the standard instructions on core programs only; the statement has
  no group restriction.

## 7. Axioms

`Print Assumptions` of each theorem may list only these four, the standard classical axioms of Rocq's standard
library, known to be consistent together with Rocq's logic:

| Axiom | Library | Why |
|---|---|---|
| `classic` (excluded middle) | `Stdlib.Logic.Classical_Prop` | case analysis on propositions, through hahn |
| `functional_extensionality_dep` | `Stdlib.Logic.FunctionalExtensionality` | equality of functions, through hahn |
| `propositional_extensionality` | `Stdlib.Logic.PropExtensionality` | equality of propositions |
| `constructive_definite_description` | `Stdlib.Logic.Description` | hahn's `ClassicalDescription` |

`assumptions.txt` holds the output; CI compares it.

## 8. Changes to the trusted files

None yet.

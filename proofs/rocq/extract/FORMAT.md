# The instance format

`AlloyDump.java` writes the executions Alloy finds in this format, and the checker extracted from Rocq
(`checker.ml`, from `Extract.v`) reads it. One execution per block, one fact per line, fields separated by single
spaces:

```
instance <name> <number>
size <events> <scopes> <addresses> <accesses>
<field> <arguments>
...
alloy <predicate> <0|1>
alloyrel <function> <x> <y>
alloyset <function> <x>
end
```

**Instances.** `<name>` is the query's file name without `.als`; `<number>` counts the instances of one query
from 0. Each block is a different execution: two solutions of Alloy that print the same block are written once.

**Atoms are numbers.** Each carrier (events, scopes, addresses, accesses) is numbered from 0, in the order of the
atoms' names as Alloy prints them, with every run of digits compared as a number: `E2$0` before `E10$0`, and
`Cta0_0_1$0` before `Gpu0$0` before `Sys$0` before `T0$0`. An access is Alloy's `Access` or `VecAccess` atom: the
two share one carrier, numbered together, as in `Ptx87.v`. The lines of one field (or one `alloyrel` or `alloyset`
function) are sorted by their arguments: numbers in increasing order, proxies and spaces in the order of the table
below.

**Fields** are the fields of the record `Exec` in `Ptx87.v`, with the same names:

| Line | Meaning | Arguments |
|---|---|---|
| `skind s K` | the kind of scope `s` | `K` is `Node`, `Cta`, `Cluster`, `Thread` or `AsyncUnit` (the most specific signature; `Thread` means a thread that is no async unit) |
| `kind e K` | the kind of event `e` | `K` is `Read`, `Acquire`, `Write`, `Release`, `FenceAcq`, `FenceRel`, `FenceAcqRel`, `FenceSC`, `AliasFence`, `PlainProxyFence`, `BarrierArrive`, `BarrierWait`, `ClusterArrive`, `ClusterWait`, `Marker` (the most specific signature: `Read` is a read that is no acquire, `FenceAcqRel` a fence that is no `FenceSC`) |
| `space a P` | the space of address `a` | `Global`, `Shared`, `Local`, `Const`, `Param` |
| `scope e s` | the scope of event `e` | |
| `init a n`, `iph a n`, `ipend a n`, `iexp a n`, `itx a n` | integer fields of addresses | `n` is a decimal integer, maybe negative |
| `val e n`, `bid e n`, `ph e n`, `pend e n`, `expc e n`, `tx e n` | integer fields of events | |
| `bcount e n`, `wpar e n`, `wtok e n` | optional integer fields (`lone Int`): one line if the field has a value | |
| `proxy e P` | the proxy of a memory event | `Generic`, `Async`, `TensorMap`, `Texture`, `Surface`, `Constant` |
| `pspace e P` | a space of a proxy fence | as for `space` |
| `dirs e P Q` | a direction `P -> Q` of a proxy fence | proxies |
| `<set> x` | `x` is in the set | `SyncRestrictCta`, `SyncRestrictCluster`, `OpRestrictInit`, `ProxyFence`, `ClusterArriveRelaxed`, `MbarEv`, `MbarInit`, `MbarWait`, `TxAnchor` (events) and `Mbar` (addresses) |
| `<relation> x y` | `x -> y` is in the relation | `subscope` (scopes), `start` (thread, event), `alias` (addresses), `owner` (address, scope), `po`, `issue`, `done`, `gdep`, `rmw`, `dep`, `rf`, `co`, `sc`, `bwait`, `bgen`, `synchronizes`, `cwait`, `cgen`, `txops` (events), `address` (event, address), `acc` and `vacc` (event, access), `paddr` (event, address) |

An integer field that has no line is 0. Alloy gives every event of a signature a value for that signature's
integer fields; only those are written (for example `val` only for memory events, `ph` only for `MbarEv`), so a
value outside a field's signature is 0, which the model never reads.

**Alloy's own answers**, for comparison: `alloy p 0|1` for each predicate `p` of the model evaluated in the
instance (`coherence`, `fence_sc`, `atomicity`, `no_thin_air`, `sc_per_location`, `causality`, `ptx_mm`,
`mb_undefined`, `undefined`, `mixed_size_race`, and the test's `outcome`); `alloyrel f x y` and `alloyset f x` for
the tuples of the derived relations and sets of the model, in the numbering above: `thd`, `aliases`,
`same_location_r`, `fr`, `com`, `po_loc`, `cta_of`, `cluster_of`, `scope_incl_r`, `footprint`, `ms_r`, `obs`,
`rel_pattern`, `acq_pattern`, `sync_pattern`, `cluster_sync`, `sw`, `rleft`, `rright`, `bco_plain`,
`sw_restricted`, `cause_base`, `pf_src`, `pf_dst`, `ppbco`, `cause`, `atomic_pair_r` (relations) and `System`,
`Weak`, `FalseWaits`, `AcqReads`, `Atomics` (sets).

The checker answers in the same form, with `rocq`, `rocqrel` and `rocqset` in place of `alloy`, `alloyrel` and
`alloyset`, and one more predicate: `wf`, which must be 1 for every instance Alloy finds.

## Pairs of executions

`dump.sh --pair --cmd <run>` reads the lowering check `models/kamui/compile_ptx87_kamui.als` (or
`proofs/rocq/als/extra.als`, which opens it). Each instance of a run holds a PTX execution (the model opened as
`p`), a Kamui execution (opened as `k`) and the map between them, written as three blocks:

```
instance <run>-p <number>
...
end
instance <run>-k <number>
...
end
map <run> <number>
ev <p-event> <k-event>
pre <p-event> <k-event>
widen <p-event>
relax <p-event>
witness <skolem> <p-event>
end
```

- The `-p` and `-k` blocks are written as above, with the `alloy` lines of the model's predicates (no
  `outcome`, no `alloyrel` or `alloyset` lines). There are no accesses in these runs (`size ... 0`).
- The PTX atoms are numbered as above. The Kamui events are numbered on their own. A Kamui scope or address gets
  the number of the PTX scope or address it is the image of (`Map.sm`, `Map.ad`), so the two blocks use the same
  numbers for them.
- `ev`, `pre`, `widen` and `relax` are the fields of `Map`: the image of a PTX event, the `fence.sc` inserted
  before it, the events with a wider scope, the read that became a generic one.
- `witness` lines give the PTX events that Alloy chose for a run's top-level `some x: ...` (the event the broken
  lowering changes): one line for each skolem relation of the solution whose atoms are PTX events, named as Alloy
  names it (for example `$broken_drop_acquire_a`).

## Mutants

`dump.sh --all --mutate N` (used by `diff.sh`) prints, for each execution of a query, the execution itself and
then executions with one field changed, each as a block of the form above with a single `alloy` line:

```
instance <name>.<field>.<change><i> <number>
size ...
...
alloy wf <0|1>
end
```

- `<change>` is `del` (a tuple removed), `add` (a tuple added) or `rep` (the last atom of a tuple replaced); at
  most `N` of each per field, chosen at random (`--seed`) among the tuples of the field's Alloy type whose atoms
  are in the execution. A field that `Ptx87.v` holds as a total function (`scope`, `space`, the integer fields)
  is only replaced, and an optional integer (`bcount`, `wpar`, `wtok`) is added only to an atom that has none, since
  `Ptx87.v` cannot hold two values there; the fields that are signatures (`SyncRestrictCta`, `Mbar`, ...) and the kinds are not changed.
- The execution itself is the block named `<name>`, with `alloy wf 1`.
- `alloy wf` is Kodkod's answer to whether the block satisfies the model's facts, its field declarations
  (`all this: S | this.f in <declared type>`) and its signature facts; the query's own facts, which pin the
  program, are left out. The checker's `rocq wf` must be the same.

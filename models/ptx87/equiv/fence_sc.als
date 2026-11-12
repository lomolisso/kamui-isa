// Fence-SC restores sequential consistency (8.10.2), checked on small executions. The manual introduces fence.sc
// for this: in a program whose memory operations are strong at the system scope, with a fence.sc between any two
// memory operations of a thread, every allowed execution is sequentially consistent. The same claim is proved
// for executions of any size in proofs/rocq/proof/FenceSC.v; this file looks for a counterexample at small bounds.
// Run with check.sh (README.md).
module fence_sc
open ptx87
open util

// The fragment of the claim: scalar generic accesses by threads (no async unit), strong at the system scope, one
// virtual address per location, and a fence.sc of system scope between any two memory operations of a thread.
pred sc_fenced {
  all e: MemoryEvent | e.proxy = Generic
  (MemoryEvent + FenceSC).scope in System
  no MemoryEvent.thd & AsyncUnit
  aliases in iden
  no acc and no vacc
  all e1, e2: MemoryEvent | e1->e2 in ^po implies some f: FenceSC | e1->f + f->e2 in ^po
}

// Sequential consistency: program order and communication have no cycle on memory operations.
pred sequentially_consistent { acyclic[MemoryEvent <: (^po + com) :> MemoryEvent] }

// Bound 6 holds SB, MP, 2+2W, R, S and LB with fences; bound 8 also IRIW.
fence_sc_6: check { (sc_fenced and ptx_mm) => sequentially_consistent } for 6 but 7 Scope, 2 Address, 0 Access, 0 VecAccess, 3 Int
fence_sc_7: check { (sc_fenced and ptx_mm) => sequentially_consistent } for 7 but 8 Scope, 2 Address, 0 Access, 0 VecAccess, 3 Int
fence_sc_8: check { (sc_fenced and ptx_mm) => sequentially_consistent } for 8 but 9 Scope, 2 Address, 0 Access, 0 VecAccess, 3 Int

// Without the fences the claim fails (store buffering is allowed), so the checks are not vacuous.
sanity_sb_without_fences: run {
  all e: MemoryEvent | e.proxy = Generic
  (MemoryEvent + FenceSC).scope in System
  no FenceSC
  ptx_mm and not sequentially_consistent
} for 4 but 5 Scope, 2 Address, 0 Access, 0 VecAccess, 3 Int
sanity_fenced: run { sc_fenced and ptx_mm and some f: FenceSC | some MemoryEvent & f.~^po and some MemoryEvent & f.^po } for 6 but 7 Scope, 2 Address, 0 Access, 0 VecAccess, 3 Int

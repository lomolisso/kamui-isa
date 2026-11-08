(** * The checkers, extracted to OCaml

    Writes [checker_core.ml] (in the build directory), which [driver.ml] uses: the checkers of [check/Check.v],
    with OCaml's own booleans, lists, pairs and options (and nothing else: numbers stay Rocq's [nat] and [Z]). *)

From Stdlib Require Extraction.
From Stdlib Require Import ExtrOcamlBasic.
From KamuiProof.lib Require Import Mat.
From KamuiProof.check Require Import FExec Check.

Set Warnings "-extraction-default-directory".

Extraction "checker_core.ml"
  valid get vget
  b_wf_prog b_wf_exec b_consistent b_coherence b_fence_sc b_atomicity b_no_thin_air b_sc_per_location
  b_causality b_mb_undefined b_undefined b_mixed_size_race
  d_thd d_aliases d_same_location_r d_fr d_com d_po_loc d_cta_of d_cluster_of d_scope_incl_r d_footprint d_ms_r
  d_obs d_rel_pattern d_acq_pattern d_sync_pattern d_cluster_sync d_sw d_rleft d_rright d_bco_plain
  d_sw_restricted d_cause_base d_pf_src d_pf_dst d_ppbco d_cause d_atomic_pair_r
  d_System d_Weak d_FalseWaits d_AcqReads d_Atomics.

(* The checker: reads executions in the format of FORMAT.md on stdin and prints, for each, the answers of the
   checkers extracted from Rocq (checker_core.ml, from Extract.v) in the same format, with "rocq", "rocqrel" and
   "rocqset" lines. Build and run, in the dev container:

     make -C proofs/rocq checker                  # build/rocq/src/checker
     build/rocq/src/checker < dump.txt > answers.txt

   Exit status 2 on a malformed block (an unknown field, an atom out of range, an event with no kind). *)

open Checker_core

let rec nat_of_int i = if i <= 0 then O else S (nat_of_int (i - 1))
let rec pos_of_int i = if i = 1 then XH else if i mod 2 = 0 then XO (pos_of_int (i / 2)) else XI (pos_of_int (i / 2))
let z_of_int i = if i = 0 then Z0 else if i > 0 then Zpos (pos_of_int i) else Zneg (pos_of_int (-i))

let fail fmt = Printf.ksprintf (fun s -> prerr_endline ("checker: " ^ s); exit 2) fmt

let scope_kind = function
  | "Node" -> SNode | "Cta" -> SCta | "Cluster" -> SCluster | "Thread" -> SThread | "AsyncUnit" -> SAsyncUnit
  | s -> fail "unknown scope kind %s" s
let event_kind = function
  | "Read" -> KRead | "Acquire" -> KAcquire | "Write" -> KWrite | "Release" -> KRelease
  | "FenceAcq" -> KFenceAcq | "FenceRel" -> KFenceRel | "FenceAcqRel" -> KFenceAcqRel | "FenceSC" -> KFenceSC
  | "AliasFence" -> KAliasFence | "PlainProxyFence" -> KPlainProxyFence
  | "BarrierArrive" -> KBarrierArrive | "BarrierWait" -> KBarrierWait
  | "ClusterArrive" -> KClusterArrive | "ClusterWait" -> KClusterWait | "Marker" -> KMarker
  | s -> fail "unknown event kind %s" s
let space_of = function
  | "Global" -> SGlobal | "Shared" -> SShared | "Local" -> SLocal | "Const" -> SConst | "Param" -> SParam
  | s -> fail "unknown space %s" s
let proxy_of = function
  | "Generic" -> Generic | "Async" -> Async | "TensorMap" -> TensorMap | "Texture" -> Texture
  | "Surface" -> Surface | "Constant" -> Constant
  | s -> fail "unknown proxy %s" s

(* The fields, by carrier: which sizes their atoms are checked against. *)
let rels = [ "subscope", ('S', 'S'); "start", ('S', 'E'); "alias", ('A', 'A'); "owner", ('A', 'S');
             "po", ('E', 'E'); "issue", ('E', 'E'); "done", ('E', 'E'); "gdep", ('E', 'E'); "rmw", ('E', 'E');
             "dep", ('E', 'E'); "rf", ('E', 'E'); "co", ('E', 'E'); "sc", ('E', 'E'); "bwait", ('E', 'E');
             "bgen", ('E', 'E'); "synchronizes", ('E', 'E'); "cwait", ('E', 'E'); "cgen", ('E', 'E');
             "txops", ('E', 'E'); "address", ('E', 'A'); "acc", ('E', 'C'); "paddr", ('E', 'A') ]
let sets = [ "SyncRestrictCta", 'E'; "SyncRestrictCluster", 'E'; "OpRestrictInit", 'E'; "ProxyFence", 'E';
             "ClusterArriveRelaxed", 'E'; "MbarEv", 'E'; "MbarInit", 'E'; "MbarWait", 'E'; "TxAnchor", 'E';
             "Mbar", 'A' ]
let ints = [ "init", 'A'; "iph", 'A'; "ipend", 'A'; "iexp", 'A'; "itx", 'A'; "val", 'E'; "bid", 'E'; "ph", 'E';
             "pend", 'E'; "expc", 'E'; "tx", 'E' ]
let opts = [ "bcount", 'E'; "wpar", 'E'; "wtok", 'E' ]

type block = { name : string; mutable size : int array; lines : (string * string list) list ref }

let process b =
  let sz c = match c with 'E' -> b.size.(0) | 'S' -> b.size.(1) | 'A' -> b.size.(2) | _ -> b.size.(3) in
  let atom c s = let i = int_of_string s in
    if i < 0 || i >= sz c then fail "%s: atom %d out of range" b.name i else i in
  let tbl = Hashtbl.create 64 in
  List.iter (fun (f, args) -> Hashtbl.add tbl f args) (List.rev !(b.lines));
  let all f = Hashtbl.find_all tbl f |> List.rev in
  let rel f = let (c1, c2) = List.assoc f rels in
    List.map (function [x; y] -> (nat_of_int (atom c1 x), nat_of_int (atom c2 y)) | _ -> fail "%s: bad %s line" b.name f) (all f) in
  let set f = let c = List.assoc f sets in
    List.map (function [x] -> nat_of_int (atom c x) | _ -> fail "%s: bad %s line" b.name f) (all f) in
  let arr f c default conv =
    let a = Array.make (sz c) None in
    List.iter (function [x; v] -> a.(atom c x) <- Some (conv v) | _ -> fail "%s: bad %s line" b.name f) (all f);
    Array.to_list (Array.map (function Some v -> v | None -> default ()) a) in
  let need f () = fail "%s: an atom has no %s line" b.name f in
  let int f = arr f (List.assoc f ints) (fun () -> Z0) (fun v -> z_of_int (int_of_string v)) in
  let opt f = arr f (List.assoc f opts) (fun () -> None) (fun v -> Some (z_of_int (int_of_string v))) in
  let pairs f conv = List.map (function [x; p] -> (nat_of_int (atom 'E' x), conv p) | _ -> fail "%s: bad %s line" b.name f) (all f) in
  let fx = {
    ne = nat_of_int (sz 'E'); ns = nat_of_int (sz 'S'); na = nat_of_int (sz 'A'); nc = nat_of_int (sz 'C');
    f_skind = arr "skind" 'S' (need "skind") scope_kind; f_subscope = rel "subscope"; f_start = rel "start";
    f_alias = rel "alias"; f_space = arr "space" 'A' (need "space") space_of; f_owner = rel "owner";
    f_init = int "init"; f_kind = arr "kind" 'E' (need "kind") event_kind; f_po = rel "po";
    f_scope = arr "scope" 'E' (need "scope") (fun v -> nat_of_int (atom 'S' v));
    f_issue = rel "issue"; f_done = rel "done"; f_gdep = rel "gdep"; f_address = rel "address";
    f_proxy = pairs "proxy" proxy_of; f_val = int "val"; f_acc = rel "acc"; f_rmw = rel "rmw"; f_dep = rel "dep";
    f_rf = rel "rf"; f_co = rel "co"; f_sc = rel "sc";
    f_SyncRestrictCta = set "SyncRestrictCta"; f_SyncRestrictCluster = set "SyncRestrictCluster";
    f_OpRestrictInit = set "OpRestrictInit"; f_ProxyFence = set "ProxyFence";
    f_dirs = List.map (function [x; p; q] -> ((nat_of_int (atom 'E' x), proxy_of p), proxy_of q)
                              | _ -> fail "%s: bad dirs line" b.name) (all "dirs");
    f_pspace = pairs "pspace" space_of; f_paddr = rel "paddr";
    f_bid = int "bid"; f_bcount = opt "bcount"; f_bwait = rel "bwait"; f_bgen = rel "bgen";
    f_synchronizes = rel "synchronizes"; f_cwait = rel "cwait"; f_cgen = rel "cgen";
    f_ClusterArriveRelaxed = set "ClusterArriveRelaxed"; f_Mbar = set "Mbar";
    f_iph = int "iph"; f_ipend = int "ipend"; f_iexp = int "iexp"; f_itx = int "itx"; f_MbarEv = set "MbarEv";
    f_ph = int "ph"; f_pend = int "pend"; f_expc = int "expc"; f_tx = int "tx"; f_MbarInit = set "MbarInit";
    f_MbarWait = set "MbarWait"; f_wpar = opt "wpar"; f_wtok = opt "wtok"; f_TxAnchor = set "TxAnchor";
    f_txops = rel "txops" } in
  let known = List.map fst rels @ List.map fst sets @ List.map fst ints @ List.map fst opts
              @ [ "skind"; "kind"; "space"; "scope"; "proxy"; "pspace"; "dirs" ] in
  Hashtbl.iter (fun f _ -> if not (List.mem f known) then fail "%s: unknown field %s" b.name f) tbl;
  if not (valid fx) then fail "%s: an event's scope is out of range" b.name;
  Printf.printf "instance %s\n" b.name;
  let pb name v = Printf.printf "rocq %s %d\n" name (if v then 1 else 0) in
  let wp = b_wf_prog fx and we = b_wf_exec fx in
  pb "wf" (wp && we); pb "wf_prog" wp; pb "wf_exec" we;
  pb "coherence" (b_coherence fx); pb "fence_sc" (b_fence_sc fx); pb "atomicity" (b_atomicity fx);
  pb "no_thin_air" (b_no_thin_air fx); pb "sc_per_location" (b_sc_per_location fx);
  pb "causality" (b_causality fx); pb "ptx_mm" (b_consistent fx); pb "mb_undefined" (b_mb_undefined fx);
  pb "undefined" (b_undefined fx); pb "mixed_size_race" (b_mixed_size_race fx);
  let prel name c1 c2 m =
    for i = 0 to sz c1 - 1 do for j = 0 to sz c2 - 1 do
      if get m (nat_of_int i) (nat_of_int j) then Printf.printf "rocqrel %s %d %d\n" name i j done done in
  let pset name c v =
    for i = 0 to sz c - 1 do if vget v (nat_of_int i) then Printf.printf "rocqset %s %d\n" name i done in
  List.iter (fun (name, c1, c2, f) -> prel name c1 c2 (f fx)) [
    "thd", 'E', 'S', d_thd; "aliases", 'A', 'A', d_aliases; "same_location_r", 'E', 'E', d_same_location_r;
    "fr", 'E', 'E', d_fr; "com", 'E', 'E', d_com; "po_loc", 'E', 'E', d_po_loc; "cta_of", 'E', 'S', d_cta_of;
    "cluster_of", 'E', 'S', d_cluster_of; "scope_incl_r", 'E', 'E', d_scope_incl_r;
    "footprint", 'E', 'A', d_footprint; "ms_r", 'E', 'E', d_ms_r; "obs", 'E', 'E', d_obs;
    "rel_pattern", 'E', 'E', d_rel_pattern; "acq_pattern", 'E', 'E', d_acq_pattern;
    "sync_pattern", 'E', 'E', d_sync_pattern; "cluster_sync", 'E', 'E', d_cluster_sync; "sw", 'E', 'E', d_sw;
    "rleft", 'E', 'E', d_rleft; "rright", 'E', 'E', d_rright; "bco_plain", 'E', 'E', d_bco_plain;
    "sw_restricted", 'E', 'E', d_sw_restricted; "cause_base", 'E', 'E', d_cause_base;
    "pf_src", 'E', 'E', d_pf_src; "pf_dst", 'E', 'E', d_pf_dst; "ppbco", 'E', 'E', d_ppbco;
    "cause", 'E', 'E', d_cause; "atomic_pair_r", 'E', 'E', d_atomic_pair_r ];
  List.iter (fun (name, c, f) -> pset name c (f fx)) [
    "System", 'S', d_System; "Weak", 'E', d_Weak; "FalseWaits", 'E', d_FalseWaits; "AcqReads", 'E', d_AcqReads;
    "Atomics", 'E', d_Atomics ];
  print_endline "end"

let () =
  let cur = ref None in
  (try while true do
    let line = input_line stdin in
    match String.split_on_char ' ' (String.trim line), !cur with
    | [ "" ], _ -> ()
    | "instance" :: rest, None ->
        cur := Some { name = String.concat " " rest; size = [| 0; 0; 0; 0 |]; lines = ref [] }
    | [ "size"; e; s; a; c ], Some b -> b.size <- Array.map int_of_string [| e; s; a; c |]
    | [ "end" ], Some b -> process b; cur := None
    | ("alloy" | "alloyrel" | "alloyset") :: _, Some _ -> ()
    | f :: args, Some b -> b.lines := (f, args) :: !(b.lines)
    | _, None -> fail "a line outside a block: %s" line
  done with End_of_file -> ());
  match !cur with Some b -> fail "%s: no end line" b.name | None -> ()

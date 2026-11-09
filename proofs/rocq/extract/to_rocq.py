#!/usr/bin/env python3
"""Write proofs/rocq/proof/Broken.v from the counterexamples Alloy found for the broken lowerings.

The input is broken/<command>.txt (next to this file): one pair of executions per broken lowering, as
`dump.sh --pair --cmd <command> --max 1 <query>` writes it (FORMAT.md, "Pairs of executions"), with the query
models/kamui/compile_ptx87_kamui.als or proofs/rocq/als/extra.als. For each, Broken.v defines the two executions
and the map as Rocq data and proves that the broken lowering fails the correctness statement on them, by
computation (Instances.v). Run after a change of these files, then commit both:

    python3 proofs/rocq/extract/to_rocq.py            # rewrite proofs/rocq/proof/Broken.v
    python3 proofs/rocq/extract/to_rocq.py --check    # fail if Broken.v is not up to date
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "proof" / "Broken.v"
CHECK = HERE.parent / "check" / "Check.v"

# The broken lowerings, in the order of broken_lowerings_fail (Theorem.v), with the sets x and dropped of their
# lowering_ex conjunct ("w" is the witness).
BROKEN = [("broken_drop_acquire", "w", ""), ("broken_narrow_fence", "w", ""), ("broken_std_weak_load", "w", ""),
          ("broken_mbar_relaxed", "w", ""), ("broken_copy_unordered", "", "w"), ("broken_drop_restrict", "w", ""),
          ("broken_drop_proxy_fence", "w", ""), ("broken_relax_nc", "", ""), ("broken_cluster_relaxed", "w", ""),
          ("broken_drop_tensormap_release", "w", "")]

SK = {"Node": "SNode", "Cta": "SCta", "Cluster": "SCluster", "Thread": "SThread", "AsyncUnit": "SAsyncUnit"}
SP = {"Global": "SGlobal", "Shared": "SShared", "Local": "SLocal", "Const": "SConst", "Param": "SParam"}
RELS = ["subscope", "start", "alias", "owner", "po", "issue", "done", "gdep", "address", "acc", "rmw", "dep", "rf",
        "co", "sc", "paddr", "bwait", "bgen", "synchronizes", "cwait", "cgen", "txops"]
SETS = ["SyncRestrictCta", "SyncRestrictCluster", "OpRestrictInit", "ProxyFence", "ClusterArriveRelaxed", "Mbar",
        "MbarEv", "MbarInit", "MbarWait", "TxAnchor"]
INTS = {"init": 2, "iph": 2, "ipend": 2, "iexp": 2, "itx": 2, "val": 0, "bid": 0, "ph": 0, "pend": 0, "expc": 0, "tx": 0}
OPTS = ["bcount", "wpar", "wtok"]
FIELDS = ["skind", "subscope", "start", "alias", "space", "owner", "init", "kind", "po", "scope", "issue", "done",
          "gdep", "address", "proxy", "val", "acc", "rmw", "dep", "rf", "co", "sc", "SyncRestrictCta",
          "SyncRestrictCluster", "OpRestrictInit", "ProxyFence", "dirs", "pspace", "paddr", "bid", "bcount", "bwait",
          "bgen", "synchronizes", "cwait", "cgen", "ClusterArriveRelaxed", "Mbar", "iph", "ipend", "iexp", "itx",
          "MbarEv", "ph", "pend", "expc", "tx", "MbarInit", "MbarWait", "wpar", "wtok", "TxAnchor", "txops"]


def blocks(text):
    out, cur = [], None
    for line in text.splitlines():
        w = line.split()
        if not w:
            continue
        if w[0] in ("instance", "map"):
            cur = (w[0], [])
        elif w[0] == "end":
            out.append(cur)
            cur = None
        elif cur is not None and w[0] not in ("alloy", "alloyrel", "alloyset"):
            cur[1].append(w)
    return out


def z(v):
    v = int(v)
    return f"({v})%Z" if v < 0 else f"{v}%Z"


def fexec(lines):
    size = next(w for w in lines if w[0] == "size")
    n = dict(zip("ESAC", map(int, size[1:])))
    by = {}
    for w in lines:
        by.setdefault(w[0], []).append(w[1:])
    def arr(f, k, conv, default):
        a = [default] * n[k]
        for x, v in by.get(f, []):
            a[int(x)] = conv(v)
        return "[" + "; ".join(a) + "]"
    vals = {
        "skind": arr("skind", "S", lambda v: SK[v], "SNode"),
        "space": arr("space", "A", lambda v: SP[v], "SGlobal"),
        "kind": arr("kind", "E", lambda v: "K" + v, "KMarker"),
        "scope": arr("scope", "E", str, "0"),
        "proxy": "[" + "; ".join(f"({x}, {p})" for x, p in by.get("proxy", [])) + "]",
        "pspace": "[" + "; ".join(f"({x}, {SP[s]})" for x, s in by.get("pspace", [])) + "]",
        "dirs": "[" + "; ".join(f"({x}, {p}, {q})" for x, p, q in by.get("dirs", [])) + "]",
    }
    for f in RELS:
        vals[f] = "[" + "; ".join(f"({x}, {y})" for x, y in by.get(f, [])) + "]"
    for f in SETS:
        vals[f] = "[" + "; ".join(x for (x,) in by.get(f, [])) + "]"
    for f, k in INTS.items():
        vals[f] = arr(f, "A" if k == 2 else "E", z, "0%Z")
    for f in OPTS:
        vals[f] = arr(f, "E", lambda v: f"Some {z(v)}", "None")
    body = "; ".join(f"f_{f} := {vals[f]}" for f in FIELDS)
    return f"{{| ne := {n['E']}; ns := {n['S']}; na := {n['A']}; nc := {n['C']};\n  {body} |}}"


def fmap(lines, ne):
    ev, pre = ["0"] * ne, ["None"] * ne
    widen, relax, wit = [], [], None
    for w in lines:
        if w[0] == "ev":
            ev[int(w[1])] = w[2]
        elif w[0] == "pre":
            pre[int(w[1])] = f"Some {w[2]}"
        elif w[0] == "widen":
            widen.append(w[1])
        elif w[0] == "relax":
            relax.append(w[1])
        elif w[0] == "witness":
            wit = int(w[2])
    m = (f"{{| m_ev := [{'; '.join(ev)}]; m_pre := [{'; '.join(pre)}]; m_widen := [{'; '.join(widen)}]; "
         f"m_relax := [{'; '.join(relax)}] |}}")
    return m, wit


def leaf():
    """The tactic that proves the specification of one checker: a match on the name of the relation or set and
    on the execution picks the lemma, so no failing lemma is tried (each try may unfold the whole execution)."""
    named, rest = [], []
    for m in re.finditer(r"^Lemma (d_[A-Za-z0-9_]*_spec)\b(.*?)\.(?:\s|$)", CHECK.read_text(), re.M | re.S):
        st = " ".join(m.group(2).split())
        mm = re.fullmatch(r": ([rs]spec) \(d_(\w+) F\) \((\w+) X\)", st)
        if mm and mm.group(2) == mm.group(3):
            named.append((mm.group(1), mm.group(2)))
        elif st.startswith(":"):
            rest.append(m.group(1))
    arms = [f"| |- {k} _ ({n} (denote FK _)) => exact (d_{n}_spec FK VK)\n"
            f"  | |- {k} _ ({n} (denote FP _)) => exact (d_{n}_spec FP VP)" for k, n in named]
    alts = [f"exact ({n} FK VK)" for n in rest] + [f"exact ({n} FP VP)" for n in rest]
    return ("Ltac leaf FP VP FK VK := first [\n  lazymatch goal with\n  " + "\n  ".join(arms) + "\n  end\n  | "
            + "\n  | ".join(alts) + "].")


def generate():
    out = ["(** * The broken lowerings fail the statement",
           "",
           "    Generated by [extract/to_rocq.py] from the counterexamples Alloy found ([extract/broken/]); do not edit.",
           "    For each broken lowering of [Lowering.v]: a PTX execution, a Kamui execution and a map between them, the",
           "    proof that they are related by the broken lowering, and the proof that the Kamui execution satisfies the",
           "    model while the PTX execution read back does not (so [correct_for] fails). The proofs compute with the",
           "    checkers of [check/], whose specifications make the computations proofs. *)",
           "",
           "From Stdlib Require Import Arith Bool List ZArith Lia.",
           "From hahn Require Import Hahn.",
           "From KamuiProof Require Import Ptx87 Kamui Lowering.",
           "Require Import KamuiProof.Theorem.",
           "From KamuiProof.lib Require Import Mat.",
           "From KamuiProof.check Require Import FExec Check CheckLowering.",
           "From KamuiProof.proof Require Import Instances.",
           "Import ListNotations.",
           "",
           leaf(),
           "",
           "Ltac groups := repeat progress unfold g_core, g_proxies, g_barriers, g_mbarrier, g_async, g_restricted, g_rest, no_async,",
           "  no_mbar, no_barriers, no_restrict, no_proxy_ops, proxies_in, generic_only, no_extras.",
           "",
           "(** One conjunct of a broken lowering: the lowering itself, by the lowering checker, or a condition on the",
           "    two executions, by [by_bool]. *)",
           "Ltac conjuncts FP VP FK VK lowtac :=",
           "  lazymatch goal with",
           "  | |- lowering_ex _ _ _ _ _ /\\ _ => split; [lowtac | conjuncts FP VP FK VK lowtac]",
           "  | |- lowering_ex _ _ _ _ _ => lowtac",
           "  | |- _ /\\ _ => split; [groups; by_bool ltac:(leaf FP VP FK VK) | conjuncts FP VP FK VK lowtac]",
           "  | |- _ => groups; by_bool ltac:(leaf FP VP FK VK)",
           "  end.",
           ""]
    names = []
    for i, (cmd, xs, ds) in enumerate(BROKEN, 1):
        bl = blocks((HERE / "broken" / f"{cmd}.txt").read_text())
        p, k = bl[0][1], bl[1][1]
        mp = next(b[1] for b in bl if b[0] == "map")
        ne = int(next(w for w in p if w[0] == "size")[1])
        m, wit = fmap(mp, ne)
        b = f"bk{i}"
        lx = "[fin_val w]" if xs else "[]"
        ld = "[fin_val w]" if ds else "[]"
        sx = "apply set1_mem" if xs else "apply none_mem"
        sd = "apply set1_mem" if ds else "apply none_mem"
        if wit is None:
            lx, ld = "[]", "[]"
        out += [f"(** [{cmd}] *)",
                f"Definition {b}_p : FExec := {fexec(p)}.",
                f"Definition {b}_k : FExec := {fexec(k)}.",
                f"Definition {b}_m : FMap := {m}.",
                f"Definition {b}_vp : valid {b}_p = true := eq_refl.",
                f"Definition {b}_vk : valid (align {b}_k {b}_p) = true := eq_refl.",
                f"Definition {b}_vm : mvalid (ne {b}_p) (ne {b}_k) {b}_m = true := eq_refl.",
                "",
                f"Lemma {b}_fails : ~ correct_for (fun EP EK S A C P K M => {cmd} P K M).",
                "Proof.",
                f"  apply (@broken_by_computation _ {b}_p {b}_k {b}_m {b}_vp {b}_vk {b}_vm).",
                "  1-4: vm_compute; reflexivity.",
                f"  cbv beta; unfold {cmd}."]
        lowtac = (f"(assert (B : b_lowering_ex {b}_p {b}_k {b}_m {lx} {ld} = true) by (vm_compute; reflexivity); "
                  f"eapply lowering_ex_ext; [| | exact (proj1 (b_lowering_ex_spec {b}_p {b}_k {b}_m {lx} {ld} {b}_vp "
                  f"{b}_vk {b}_vm) B)]; [intros e; {sx} | intros e; {sd}])")
        if wit is not None:
            out.append(f"  set (w := @to_fin {ne} {wit} ltac:(repeat constructor)); exists w.")
        out += [f"  conjuncts {b}_p {b}_vp (align {b}_k {b}_p) {b}_vk ltac:({lowtac}).", "Qed.", ""]
        names.append(f"{b}_fails")
    out += ["Theorem lowering_broken_fail : broken_lowerings_fail.",
            "Proof.",
            "  unfold broken_lowerings_fail.",
            "  " + "".join(f"split; [exact {n} |]; " for n in names[:-1]) + f"exact {names[-1]}.",
            "Qed.", ""]
    return "\n".join(out)


def main():
    text = generate()
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit(f"{OUT} is not up to date: run {Path(__file__).name}")
        return
    OUT.write_text(text)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()

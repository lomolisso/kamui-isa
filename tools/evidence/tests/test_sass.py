"""Unit tests of the SASS annotation (no ptxas, cuobjdump or nvdisasm needed)."""

import annotate as A
import common
import sass as S


def fn(*insns, name="k"):
    """A function in nvdisasm -json form from (predicate, opcode, operands) triples."""
    return {"function-name": name, "sass-instructions": [
        {**({"predicate": p} if p else {}), "opcode": o, "operands": a} for p, o, a in insns]}


VECADD = fn(("", "LDC", "R1,c[0x0][0x28]"), ("", "S2R", "R0,SR_TID.X"), ("", "S2UR", "UR4,SR_CTAID.X"),
            ("", "LDC", "R9,c[0x0][RZ]"), ("", "IMAD", "R9,R9,UR4,R0"), ("", "ULDC", "UR4,c[0x0][0x228]"),
            ("", "ISETP.GE.AND", "P0,PT,R9,UR4,PT"), ("@P0", "EXIT", ""), ("", "LDC.64", "R4,c[0x0][0x218]"),
            ("", "IMAD.WIDE", "R4,R9,0x4,R4"), ("", "LDG.E", "R5,desc[UR4][R4.64]"), ("", "FADD", "R9,R6,R5"),
            ("", "STG.E", "desc[UR4][R2.64],R9"), ("", "EXIT", ""), ("", "BRA", "0x140"), ("", "NOP", ""))


def test_harness_leaves_only_the_work():
    [f] = A.sass_functions([VECADD])
    h = A.harness(f)
    assert [i.opcode for k, i in enumerate(f) if k not in h] == ["LDG.E", "FADD", "STG.E"]


def test_patterns_end_at_a_dot():
    [f] = A.sass_functions([fn(("", "LDG.E", "R1,desc[UR4][R2.64]"), ("", "LD.E", "R1,[R2.64]"),
                               ("", "LDC", "R1,c[0x3][0x0]"), ("", "LDC", "R1,c[0x0][0x210]"))])
    assert [i.opcode for i in f if A.matches(["LD"], i)] == ["LD.E"]
    assert [i.operands for i in f if A.matches(["LDC@c\\[0x3\\]"], i)] == ["R1,c[0x3][0x0]"]


def test_class_lookup_uses_the_state_space_anywhere():
    classes = A.load_classes()
    assert A.class_patterns(["ld.relaxed.sys.global.u32"], classes)[1] == ["ld.global"]
    assert A.class_patterns(["ld.shared::cluster.u32"], classes)[1] == ["ld.shared::cluster"]
    assert A.class_patterns(["st.async.shared::cluster.mbarrier::complete_tx::bytes.u32"], classes)[1] == ["st.async"]
    assert A.class_patterns(["cp.async.bulk.tensor.2d.shared::cluster.global.tile"], classes)[1] == \
        ["cp.async.bulk.tensor"]
    assert A.class_patterns(["ld.u32"], classes)[1] == ["ld"]


def test_every_class_pattern_compiles_and_every_emulated_row_exists():
    classes = A.load_classes()
    ids = {r["id"] for r in common.load_catalog()}
    for pats in list(classes["classes"].values()) + list(classes["spaces"].values()):
        for p in pats:
            A.matches([p], A.Insn("k", 0, "", "X", ""))
    assert set(classes["emulated"]) <= ids
    assert set(A.load_review()) <= ids


def test_mechanisms():
    funcs = A.sass_functions([fn(("", "VOTE.ANY", "R0,PT,PT"), ("", "FLO.U32", "R1,R0"), ("", "BSSY", "B0,0x100"),
                                 ("", "MEMBAR.ALL.GPU", ""), ("@P0", "ATOMG.E.ADD.STRONG.GPU", "R2,desc[UR4][R4.64],R3"),
                                 ("", "CCTL.IVALL", ""), ("", "BSYNC", "B0"), ("", "SHFL.IDX", "R5,R2,R1,0x1f"))])
    anchors = [i for i in funcs[0] if i.opcode.startswith("ATOMG")]
    m = A.mechanisms(funcs, anchors, ["atom.acq_rel.gpu.global.add.u32"], False)
    assert m == ["convergence-barrier", "warp-aggregation", "memory-barrier", "cache-maintenance"]
    assert A.modifier_encoding(["atom.acq_rel.gpu.global.add.u32"], anchors, A.region_opcodes(funcs, anchors)) == \
        ".acq_rel -> MEMBAR before + CCTL.IVALL after; .gpu -> STRONG.GPU; .global -> ATOMG"


def test_desc_operand_is_not_uniform_datapath_but_gdesc_is():
    f = A.sass_functions([fn(("", "LDG.E", "R5,desc[UR4][R4.64]"), ("", "HGMMA.64x8x16.F32", "R24,gdesc[UR4],RZ"))])
    ldg, hgmma = f[0]
    assert A.mechanisms(f, [ldg], ["ld.global.u32"], False) == ["none"]
    assert A.mechanisms(f, [hgmma], ["wgmma.mma_async"], False) == ["uniform-datapath", "descriptor"]


def test_ptx_statements_and_numbers():
    ptx = "\t@%p1 bra \t$L__BB0_2;\n\tmad.lo.cc.u32 %r1, %r2, %r3, %r4; madc.hi.u32 %r5, %r2, %r3, %r6;\n$L__BB0_2:\n"
    assert A.ptx_instructions(ptx) == ["bra", "mad.lo.cc.u32", "madc.hi.u32"]
    out = ("ptxas info    : Compiling entry function 'k' for 'sm_90a'\nptxas info    : Function properties for k\n"
           "    0 bytes stack frame\nptxas info    : Used 12 registers, used 1 barriers, 512 bytes smem\n")
    assert A.ptxas_numbers(out) == ("12", "512")
    assert A.resusage_shared(" Function k:\n  REG:12 STACK:0 SHARED:1536 LOCAL:0\n") == "1536"


def test_compile_time_is_dropped():
    assert S.COMPILE_TIME_RE.sub("", "a\nptxas info    : Compile time = 2.0 ms\nb\n") == "a\nb\n"


def test_committed_evidence_is_complete():
    assert A.check(common.load_catalog()) == 0

import pytest

import gen_families
import litmus
import to_alloy
import to_riscv

MP = """PTX MP
{
x=0; y=0;
}
 P0@cta 0,gpu 0         | P1@cta 1,gpu 0         ;
 st.weak x, 1           | ld.acquire.gpu r0, y   ;
 st.release.gpu y, 1    | ld.weak r1, x          ;
exists
(P1:r0 == 1 /\\ P1:r1 == 0)
"""


def test_alloy_mp():
    t = litmus.parse(MP)
    als = to_alloy.translate(t, "ptx/x/MP")
    assert "open ptx" in als
    assert "one sig E0, E3 extends Read" not in als
    assert "one sig E2 extends Acquire {}" in als and "one sig E1 extends Release {}" in als
    assert "subscope = Sys->Gpu0 + Gpu0->Cta0_0 + Cta0_0->T0 + Gpu0->Cta0_1 + Cta0_1->T1" in als
    assert "scope = E0->T0 + E1->Gpu0 + E2->Gpu0 + E3->T1" in als
    assert "pred outcome { ((E2 in (E1).rf) and (no rf.E3)) }" in als
    assert to_alloy.model_name(t) == "ptx-2019-alloy"


def test_alloy_cluster_and_final_value():
    t = litmus.parse(MP.replace("cta 0,gpu", "cta 0,cluster 0,gpu").replace("cta 1,gpu", "cta 1,cluster 0,gpu")
                     .replace("release.gpu", "release.cluster").replace("acquire.gpu", "acquire.cluster")
                     .replace("P1:r1 == 0", "x == 1"))
    als = to_alloy.translate(t, "c")
    assert "Gpu0->Cl0_0" in als and "Cl0_0->Cta0_0" in als and "E1->Cl0_0" in als
    assert "(no none)" in als  # x == 1: the only write to x is final
    assert to_alloy.model_name(t) == "ptx-2019-alloy+ext"


@pytest.mark.parametrize("change,why", [
    (("st.weak x, 1", "sust.weak x, 1"), "prox"),
    (("st.weak x, 1", "atom.relaxed.gpu.add r5, x, 1"), "instruction"),
    (("st.weak x, 1", "st.weak.shared::cta x, 1"), "state-space"),
])
def test_alloy_unsupported(change, why):
    with pytest.raises(to_alloy.Unsupported, match=why):
        to_alloy.translate(litmus.parse(MP.replace(*change)), "u")


def test_riscv_mp():
    out = to_riscv.translate(litmus.parse(MP))
    lines = [ln for ln in out.splitlines()]
    assert lines[0] == "RISCV MP"
    assert "0:x5=x; 0:x6=y; 1:x5=y; 1:x6=x;" in out
    assert " fence rw,w " in out and "fence r,rw" in out
    assert out.rstrip().endswith("exists (1:x10=1 /\\ 1:x11=0)")


def test_riscv_amo_and_red():
    t = litmus.parse(MP.replace("st.weak x, 1", "red.relaxed.gpu.add x, 1")
                     .replace("ld.weak r1, x", "atom.acq_rel.gpu.exch r1, x, 2"))
    out = to_riscv.translate(t)
    assert "amoadd.w x0,x7,(x5)" in out and "amoswap.w.aqrl x11,x7,(x6)" in out


def test_riscv_unsupported():
    with pytest.raises(to_riscv.Unsupported):
        to_riscv.translate(litmus.parse(MP.replace("st.weak x, 1", "bar.cta.sync 1")))


def test_families():
    files = gen_families.generate()
    assert len(files) == 288
    names = [p.stem for p in files]
    assert len(set(names)) == len(names)
    t = litmus.parse(files[gen_families.OUT / "IRIW" / "IRIW+fence-sc.gpu+same-cluster.litmus"])
    assert [(th.cta, th.cluster) for th in t.threads] == [(0, 0), (1, 0), (2, 0), (3, 0)]
    assert t.threads[2].instrs[1].text == "fence.sc.gpu"
    assert t.dartagnan_ok and not t.uses_cluster_scope
    t = litmus.parse(files[gen_families.OUT / "MP" / "MP+fence-rel-acq.cluster+diff-cluster.litmus"])
    assert t.uses_ptx86_fences and not t.dartagnan_ok
    assert "cluster" not in t.without_clusters().split("}")[1].split(";")[0]

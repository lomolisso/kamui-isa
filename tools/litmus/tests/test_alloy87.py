"""Tests of tools/litmus/to_alloy87.py (the PTX 8.7 Alloy translator). No Alloy needed."""

import pytest

import litmus
import to_alloy87

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


def q(text: str) -> str:
    return to_alloy87.translate(litmus.parse(text), "ptx/x/t")


def test_mp_shape_and_values():
    als = q(MP)
    assert "open ptx87" in als
    assert "one sig E1 extends Release {}" in als and "one sig E2 extends Acquire {}" in als
    assert "scope = E0->T0 + E1->Gpu0 + E2->Gpu0 + E3->T1" in als
    assert "E0.val = 1" in als and "E1.val = 1" in als
    assert "pred outcome { ((E2.val = 1) and (E3.val = 0)) }" in als
    assert "run test { ptx_mm and (outcome or undefined) }" in als
    assert "run consistent { ptx_mm }" in als


def test_rmw_values_and_failing_cas():
    t = MP.replace("st.release.gpu y, 1", "atom.relaxed.gpu.cas r2, y, 0, 1").replace("P1:r1 == 0", "y == 1")
    als = q(t)
    assert "lone sig E2 extends Write {}" in als
    assert "some E2 <=> E1.val = 0" in als and "all w: E2 | w.val = 1" in als
    assert "rmw = E1->E2" in als
    assert "(some E2 and E2.val = 1)" in als  # the final value of y


def test_proxy_view_shares_the_address():
    t = MP.replace("x=0; y=0;", "x=0; y=0; s @ surface aliases x;").replace("ld.weak r1, x", "suld.weak r1, s")
    als = q(t)
    assert "E3->L_x" in als and "E3->Surface" in als and "L_s" not in als


def test_generic_alias_is_a_new_address():
    t = MP.replace("x=0; y=0;", "x=0; y=0; z @ generic aliases x;").replace("ld.weak r1, x", "ld.weak r1, z")
    als = q(t)
    assert "alias = L_z->L_x" in als and "E3->L_z" in als


def test_mbarrier():
    t = """PTX MB
{
b=mbarrier(1);
x=0;
}
 P0@cta 0,gpu 0                 | P1@cta 0,gpu 0                                 ;
 st.weak x, 1                   | mbarrier.test_wait.parity.acquire.cta r0, b, 0 ;
 mbarrier.arrive.release.cta b  | ld.weak r1, x                                  ;
exists
(P1:r0 == 1 /\\ P1:r1 == 0)
"""
    als = q(t)
    assert "Mbar = L_b" in als and "L_b.iph = 0 and L_b.ipend = 1" in als
    assert "mb_next[E1, E2, 1, 0, 0]" in als
    assert "MbarWait = E3" in als and "E3.wpar = 0" in als
    assert "(wait_true[E3] => 1 else 0) = 1" in als
    assert "owner = L_b->Cta0_0_0" in als


def test_bulk_copy_units_and_complete_tx():
    t = """PTX TMA
{
g=5; d=0 @cta 0; b=mbarrier(1) @cta 0;
}
 P0@cta 0,cluster 0,gpu 0                                                    ;
 mbarrier.arrive.expect_tx.release.cta b, 1                                  ;
 cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes d, g, b   ;
 mbarrier.test_wait.parity.acquire.cta r0, b, 0                              ;
 ld.weak.shared::cta r1, d                                                   ;
exists
(P0:r0 == 1 /\\ P0:r1 != 5)
"""
    als = q(t)
    assert "one sig U0, U1 extends AsyncUnit {}" in als
    assert "Cta0_0_0->U0" in als and "Cta0_0_0->U1" in als
    assert "TxAnchor = " in als and ".txops = " in als
    assert "issue = " in als and "done = " in als
    assert "Async->Generic + Generic->Async" in als


def test_restricted_fence_and_cluster_barrier():
    t = """PTX R
{
s=0 @cta 0;
}
 P0@cta 0,cluster 0,gpu 0                         | P1@cta 1,cluster 0,gpu 0        ;
 st.weak.shared::cta s, 1                         | barrier.cluster.arrive          ;
 fence.release.sync_restrict::shared::cta.cluster | barrier.cluster.wait            ;
 barrier.cluster.arrive.relaxed                   | ld.weak.shared::cluster r0, s   ;
 barrier.cluster.wait                             |                                 ;
exists
(P1:r0 == 0)
"""
    als = q(t)
    assert "SyncRestrictCta = E1" in als and "ClusterArriveRelaxed = E2" in als
    assert "cwait = E2->E3 + E4->E5" in als


def test_vector_free_order():
    t = MP.replace("st.release.gpu y, 1", "st.release.gpu.v2 y, z, 1, 1")
    als = q(t)
    assert "or" in [line for line in als.splitlines() if "po =" in line][0]


def test_unsupported():
    with pytest.raises(to_alloy87.Unsupported):
        q(MP.replace("ld.weak r1, x", "LC00:"))

from pathlib import Path

import litmus
import to_alloy87
import to_kamui

SUITE = Path(__file__).resolve().parents[3] / "tests" / "litmus"

MP = """PTX MP
"test"
{
x=0;
y=0;
}
 P0@cta 0,gpu 0        | P1@cta 1,gpu 0          ;
 st.weak x, 1          | ld.acquire.gpu r0, y    ;
 st.release.gpu y, 1   | ld.weak r1, x           ;
exists
(P1:r0 == 1 /\\ P1:r1 == 0)
"""


def test_fence_table():
    assert to_kamui.fence_kind("rw", "rw") == "fence.sc.sys"
    assert to_kamui.fence_kind("w", "r") == "fence.sc.sys"
    assert to_kamui.fence_kind("r", "rw") == "fence.acquire.sys"
    assert to_kamui.fence_kind("rw", "w") == "fence.release.sys"
    assert to_kamui.fence_kind("w", "w") == "fence.release.sys"
    assert to_kamui.fence_kind("r", "w") == "fence.acquire.sys"
    assert to_kamui.fence_kind("o", "i") == "fence.sc.sys"


def test_lower_mp_both_variants():
    t = litmus.parse(MP)
    kamui, used = to_kamui.lower(t, "kamui")
    assert "kstg.weak" not in kamui and "kst.weak x, 1" in kamui and "kld.acquire.gpu r0, y" in kamui
    assert used["st"] == 2 and used["ld"] == 2
    std, _ = to_kamui.lower(t, "std")
    assert "sw x, 1" in std and "lw.aq r0, y" in std and "sw.rl y, 1" in std


def test_expansion_gives_the_ptx_events():
    """Lowering MP and reading it back gives the same events as the PTX test (scopes widened in std)."""
    t = litmus.parse(MP)
    e = to_kamui.Expander()
    for variant, want in (("kamui", ["st.weak x, 1", "st.release.gpu y, 1"]),
                          ("std", ["st.weak x, 1", "st.release.sys y, 1"])):
        text, _ = to_kamui.lower(t, variant)
        u, _ = e.expand(litmus.parse(text))
        assert [i.text for i in u.threads[0].instrs] == want


def test_standard_instruction_meanings():
    e = to_kamui.Expander()
    p = litmus.parse_instr
    assert e.instr(p("amoswap.w.aqrl r0, x, 1")) == ["fence.sc.sys", "atom.acq_rel.sys.exch r0, x, 1"]
    assert e.instr(p("amoadd.w x0, x, 1")) == ["red.relaxed.sys.add x, 1"]
    assert e.instr(p("amocas.q r0, x, 0, 1")) == ["atom.relaxed.sys.cas.b128 r0, x, 0, 1"]
    assert e.instr(p("lw.aqrl r0, x")) == ["fence.sc.sys", "ld.acquire.sys r0, x"]
    assert e.instr(p("fence.tso")) == ["fence.acq_rel.sys"]
    assert e.instr(p("cbo.inval x")) == ["discard.global.L2 x, 128"]
    assert e.instr(p("prefetch.r x")) == []


def test_kamui_instruction_meanings():
    e = to_kamui.Expander()
    p = litmus.parse_instr
    assert e.instr(p("kmbar.arv.release.cluster.remote b")) == ["mbarrier.arrive.release.cluster.shared::cluster b"]
    assert e.instr(p("kblkcp.s.g.mc d0+d1, g, b0+b1")) == [
        "cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes.multicast::cluster d0+d1, g, b0+b1"]
    assert e.instr(p("kfence.proxy.async.shared_cta")) == ["fence.proxy.async.shared::cta"]
    assert e.instr(p("kwarpgroup.commit")) == ["wgmma.commit_group.sync.aligned"]
    assert e.instr(p("kldg.nc r0, x")) == ["ld.global.nc r0, x"]


def test_ldu_is_an_ordinary_weak_load():
    t = litmus.parse(MP.replace("ld.weak r1, x", "ldu.global r1, x"))
    for variant in to_kamui.VARIANTS:
        text, _ = to_kamui.lower(t, variant)
        assert "kldg.weak r1, x" in text


def test_query_opens_the_kamui_model():
    t = litmus.parse(MP)
    text, _ = to_kamui.lower(t, "kamui")
    q = to_kamui.translate_kamui(litmus.parse(text), "MP", "kamui-isa/kamui/MP")
    assert "\nopen kamui\n" in q and "open ptx87" not in q
    ptx = to_alloy87.translate(t, "MP")
    body = lambda s: s[s.index("fact shape"):]  # noqa: E731
    assert body(q) == body(ptx)  # the same events and relations


def test_committed_hand_tests_parse():
    for p in to_kamui.hand_tests():
        t = litmus.load(p)
        assert t.arch == "KAMUI"
        to_kamui.translate_kamui(t, "x", "x")


def test_correspondence_names_every_field():
    import check_suite
    root = SUITE.parents[1]
    model = (root / "models" / "ptx87" / "ptx87.als").read_text()
    check = (root / "models" / "kamui" / "compile_ptx87_kamui.als").read_text()
    assert check_suite.correspondence_errors(model, check) == []
    grown = model.replace("  wtok: lone Int\n", "  wtok: lone Int,\n  wnew: lone Int\n").replace(
        "sig ClusterWait extends Event {}", "sig ClusterWait extends Event {}\nsig NewEvent extends Event {}")
    errors = check_suite.correspondence_errors(grown, check)
    assert any("field wnew" in e for e in errors) and any("signature NewEvent" in e for e in errors)

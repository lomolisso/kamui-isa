import pytest

import import_tests
import litmus

MP = """PTX MP-test
"A comment
on two lines"
{
x=0; y=0;
P1:r1=0;
}
 P0@cta 0,gpu 0       | P1@cta 1,gpu 0        ;
 st.weak x, 1         | ld.acquire.gpu r1, y  ;
 st.release.gpu y, 1  | ld.weak r2, x         ;
~exists
(P1:r1 == 1 /\\ P1: r2 != 1)
"""


def test_parse_mp():
    t = litmus.parse(MP)
    assert t.name == "MP-test"
    assert [th.placement for th in t.threads] == ["P0@cta 0,gpu 0", "P1@cta 1,gpu 0"]
    i = t.threads[1].instrs[0]
    assert (i.op, i.order, i.scope, i.args) == ("ld", "acquire", "gpu", ["r1", "y"])
    assert t.quantifier == "~exists"
    assert t.condition == litmus.And((litmus.Cmp("P1:r1", "==", "1"), litmus.Cmp("P1:r2", "!=", "1")))
    assert t.locations == ["x", "y"]
    assert not t.uses_proxy and not t.uses_cluster and not t.has_loops


def test_cluster_extension():
    t = litmus.parse(MP.replace("P0@cta 0,gpu 0", "P0@cta 0,cluster 0,gpu 0"))
    assert t.threads[0].cluster == 0 and t.uses_cluster
    t = litmus.parse(MP.replace("st.release.gpu", "st.release.cluster"))
    assert t.uses_cluster


@pytest.mark.parametrize("quant,cond,expect", [
    ("exists", "(P0:r0 == 1)", "exists\n(P0:r0 == 1)"),
    ("~exists", "(P0:r0 == 1)", "exists\n(P0:r0 == 1)"),
    ("forall", "(P0:r0 == 1 \\/ x = 2)", "exists\n~((P0:r0 == 1 \\/ x = 2))"),
])
def test_normalize(quant, cond, expect):
    text = MP.split("~exists")[0] + f"{quant}\n{cond}\n"
    new, q = litmus.normalize(text)
    assert q == quant
    assert new.endswith(expect + "\n")
    assert new.startswith(MP.split("~exists")[0])
    assert litmus.parse(new).quantifier == "exists"


def test_expected_from_quantifier():
    assert litmus.expected_from_quantifier("exists", True) == "allowed"
    assert litmus.expected_from_quantifier("exists", False) == "forbidden"
    assert litmus.expected_from_quantifier("~exists", True) == "forbidden"
    assert litmus.expected_from_quantifier("forall", False) == "allowed"


def test_condition_errors():
    with pytest.raises(litmus.LitmusError):
        litmus.parse_condition("(P0:r0 == 1")
    with pytest.raises(litmus.LitmusError):
        litmus.parse_condition("P0:r0 1")


def test_format_round_trip():
    t = litmus.parse(MP)
    again = litmus.parse(t.format())
    assert [[i.text for i in th.instrs] for th in again.threads] == [[i.text for i in th.instrs] for th in t.threads]
    assert again.condition == t.condition


def test_proxy_and_loops():
    t = litmus.parse("""PTX p
{
x=0; s @ surface aliases x;
}
 P0@cta 0,gpu 0 ;
 LC00: ;
 sust.weak s, 1 ;
 fence.proxy.surface ;
 beq r0, 1, LC00 ;
exists (x == 1)
""")
    assert t.uses_proxy and t.has_loops
    assert t.threads[0].instrs[0].label == "LC00"


def test_mixedproxy_expand_and_translate():
    src = """.global x;
.surfref s virtually aliases x;
.global flag;

d0.b0.t0 {
  $0, 2;
  st.release.gpu [flag], 1;
}

d0.b1.t0 {
  ld.acquire.gpu r0, [flag] == 1;
  $1 r1, $2;
}

$3(r1 $4 2) as r1;

$$

st   [x] | ld   | [x] | assert | ==
sust [s] | suld | [s] | permit | !=
"""
    variants = import_tests.expand_templates(src)
    assert len(variants) == 2
    text, expected, _ = import_tests.translate_mixedproxy(variants[0], "MP+00")
    t = litmus.parse(text)
    assert expected == "forbidden"
    assert [i.text for i in t.threads[0].instrs] == ["st.weak x, 2", "st.release.gpu flag, 1"]
    assert [i.text for i in t.threads[1].instrs] == ["ld.acquire.gpu r0, flag", "ld.weak r1, x"]
    assert t.threads[1].cta == 1
    assert t.condition == litmus.And((litmus.Cmp("P1:r0", "==", "1"), litmus.Not(litmus.Cmp("P1:r1", "==", "2"))))
    text, expected, _ = import_tests.translate_mixedproxy(variants[1], "MP+01")
    t = litmus.parse(text)
    assert expected == "allowed" and "s @ surface aliases x" in t.init
    assert t.threads[1].instrs[1].text == "suld.weak r1, s"


def test_mixedproxy_volatile_and_atom():
    src = """.global x;
d0.b0.t0 {
  st.volatile [x], 1;
  atom.add.acq_rel.gpu r1, [x], 1;
}
permit (r1 == 1) as a;
"""
    text, expected, note = import_tests.translate_mixedproxy(src, "v")
    t = litmus.parse(text)
    assert [i.text for i in t.threads[0].instrs] == ["st.relaxed.sys x, 1", "atom.acq_rel.gpu.add r1, x, 1"]
    assert "volatile" in note and expected == "allowed"
